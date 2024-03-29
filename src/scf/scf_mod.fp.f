!-----------------------------------------------------------------------
! PSCF - Polymer Self-Consistent Field Theory
! Copyright (2002-2016) Regents of the University of Minnesota
! contact: David Morse, morse012@umn.edu
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation. A copy of this license is included in
! the LICENSE file in the top-level PSCF directory. 
!----------------------------------------------------------------------
!****m scf/scf_mod
! PURPOSE
!   Calculate monomer concentrations, free energies, and stresses.
!   Solve the modified diffusion equation for chains by a pseudo-spectral 
!   algorithm. Use a simple Boltzmann weight on a grid for solvent.
! AUTHOR 
!   Jian Qin - Implemented pseudo-spectral algorithm (2005-2006)
!   Raghuram Thiagarajan - Added small molecule solvent (2007)
! SOURCE
!----------------------------------------------------------------------
module scf_mod 
   use const_mod
   use chemistry_mod
   use fft_mod
   use grid_mod
   use grid_basis_mod 
   use chain_mod
   use step_mod
   implicit none

   private

   ! public procedures
   public:: density_startup   ! allocates arrays needed by density
   public:: density           ! scf calculation of rho & q
   public:: scf_stress        ! calculates d(free energy)/d(cell_param)
   public:: mu_phi_chain      ! calculates mu from phi (canonical)
                              ! or phi from mu (grand) for chains
   public:: mu_phi_solvent    ! calculates mu from phi (canonical)
                              ! or phi from mu (grand) for solvents
   public:: free_energy       ! calculates helmholtz free energy 
                              ! (optionally calculates pressure)
   public:: free_energy_FH    ! Flory-Huggins helmholtz free energy
   public:: set_omega_uniform ! sets k=0 component of omega (canonical)
   
   !# ifdef DEVEL
   public:: divide_energy     ! calculates different components of free energy
   !# endif

   ! public module variable 
   public:: plan              ! module variable, used in iterate_mod
   public:: chains 

   !***

   !****v scf_mod/plan -------------------------------------------------
   ! VARIABLE
   !     type(fft_plan) plan - Plan of grid sizes etc. used for FFTs
   !                           (Public because its used in iterate_mod)
   !*** ----------------------------------------------------------------


   type(fft_plan)                             :: plan

   type(chain_grid_type),allocatable          :: chains(:)
   integer                                    :: extrap_order

   real(long),allocatable :: q0(:,:,:)      ! temp storage of 0th step for Gaussian block 
   real(long),allocatable :: qwj0(:,:,:,:)  ! temp storage of 0th step for wormlike block
   real(long),allocatable :: qw0(:,:,:,:)   ! temp storage of 0th step for wormlike block          
   real(long), allocatable :: qr0(:,:,:)    ! temp storage 

   !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
   ! Generic Interfaces
   !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
   
   !------------------------------------------------------------------
   !****p scf_mod/rho_field
   ! SUBROUTINE rho_field 
   ! COMMENT
   !
   !  a) Taking propagator and evaluate the density of monomer 
   !
   ! SOURCE
   !------------------------------------------------------------------
   interface rho_field 
      module procedure rho_field_gaussian
      module procedure rho_field_wormlike 
   end interface 
   
contains

   !--------------------------------------------------------------------
   !****p scf_mod/density_startup
   ! SUBROUTINE
   !    subroutine density_startup(N_grids,extr_order,chain_step,update_chain)
   !
   ! PURPOSE
   !    Initialize FFT_plan, grid_data.
   !    Allocate or update/re-allocate memory for chains
   !
   ! ARGUMENTS
   !    N_grids      = grid dimensions
   !    extr_order   = Richardson extrapolation order
   !    chain_step   = the discretized chain segment length
   !    update_chain = true if simply the chain memory need to be re-allocated
   !
   ! SOURCE
   !--------------------------------------------------------------------
   subroutine density_startup(N_grids, extr_order, chain_step, update_chain)
   implicit none

   integer, intent(IN)    :: N_grids(3) ! # of grid points in each direction
   integer, intent(IN)    :: extr_order
   real(long), intent(IN) :: chain_step(:,:)
   logical, intent(IN)    :: update_chain
   !***

   integer :: i, nblk, error
   integer :: nx,ny,nz    
   integer :: order 


   if (.NOT. allocated(q0) ) then 
      allocate(q0(0:N_grids(1)-1,0:N_grids(2)-1,0:N_grids(3)-1),STAT=error)
      if(error /= 0) STOP "q0 allocation error in scf_mod/density_startup"

      allocate(qr0(0:N_grids(1)-1,0:N_grids(2)-1,0:N_grids(3)-1),STAT=error)
      if(error /= 0) STOP "qr0 allocation error in scf_mod/density_startup"
   endif


   if (.NOT. allocated(qw0) ) then
      allocate(qw0(0:N_grids(1)-1,0:N_grids(2)-1,0:N_grids(3)-1,0:N_sph-1),STAT=error)
      if(error /= 0) STOP "q0 allocation error in scf_mod/density_startup"
      allocate(qwj0(0:N_grids(1)-1,0:N_grids(2)-1,0:N_grids(3)-1,0:N_sph-1),STAT=error)
      if(error /= 0) STOP "q0 allocation error in scf_mod/density_startup"
   endif

   if ( .NOT. update_chain ) then
      call create_fft_plan(N_grids,plan)
      if (N_chain > 0) then
         allocate(chains(N_chain),STAT=error)
         if(error /= 0) STOP "chains allocation error in scf_mod/density_startup"
         do i=1, N_chain
           nblk      = N_block(i)
           call null_chain_grid(chains(i))
           call make_chain_grid(chains(i),plan,nblk,&
              block_length(1:nblk,i),block_type(1:nblk,i),chain_step(1:nblk,i))
         end do
      end if
      call init_step(N_grids,chains)
      extrap_order = extr_order   ! set up global variable
   else
      do i=1, N_chain
        nblk = N_block(i)
        call destroy_chain_grid(chains(i))
        call make_chain_grid(chains(i),plan,nblk,&
           block_length(1:nblk,i),block_type(1:nblk,i),chain_step(1:nblk,i))
      end do
   end if
   
   end subroutine density_startup
   !====================================================================


   !-----------------------------------------------------------------
   !****p scf_mod/density
   ! SUBROUTINE
   !    density(N,omega,rho,qout,q_solvent)
   !
   ! PURPOSE
   !    Main SCFT calculation. Solve the modified diffusion equation
   !    for all polymer species, and calculate monomer density field
   !    for all monomer types. 
   !
   ! ARGUMENTS
   !    N                    = # of basis functions
   !    omega(N_monomer,N)   = chemical potential
   !    rho(N_monomer,N)     = monomer density fields
   !    qout(N_chain)        = partition functions
   !    q_solvent(N_solvent) = partition functions of solvent molecules
   !
   ! COMMENT   
   !      density_startup should be called prior to density to
   !      allocate arrays used by density and scf_stress.
   !
   ! SOURCE
   !------------------------------------------------------------------
   subroutine density( &
       N,              & ! # of basis functions
       omega,          & ! (N_monomer,N)chemical potential field
       rho,            & ! (N_monomer,N) monomer density field
       qout,           & ! (N_chain) 1-chain partition functions
       q_solvent       & ! (N_solvent) solvent partition functions
   )
   implicit none

   integer,    intent(IN)            :: N
   real(long), intent(IN)            :: omega(:,:)
   real(long), intent(OUT)           :: rho(:,:)
   real(long), intent(OUT), optional :: qout(N_chain)
   real(long), intent(OUT), optional :: q_solvent(N_solvent)

   !***
   
   ! local variables
!  complex(long)  :: kgrid(0:plan%n(1)/2, &
!                          0:plan%n(2)-1, &
!                          0:plan%n(3)-1)
   complex(long),allocatable  :: kgrid(:,:,:)

   real(long)     :: rnodes       ! number of grid points
   real(long)     :: partion      ! partion of single chain
   real(long)     :: bigQ_solvent ! partition of solvent
   integer        :: i_chain      ! index to chain
   integer        :: i_blk        ! index to block
   integer        :: alpha        ! index to monomer
   integer        :: i            ! dummy variable
   real(long)     :: Ns           ! number of solvent molecules in a reference volume  
   integer        :: info
   real*8         :: tb, te


   !call cpu_time(tb) 
   allocate( kgrid(0:plan%n(1)/2, 0:plan%n(2)-1, 0:plan%n(3)-1), stat=info)
   if( info /= 0 ) stop "density/kgrid(:,:,:) allocation error"
  
   rnodes=dble( plan%n(1) * plan%n(2) * plan%n(3) )

   ! Transform omega fields onto a grid
   do alpha = 1, N_monomer
     call basis_to_kgrid(omega(alpha,:),kgrid)
     call ifft(plan,kgrid,omega_grid(:,:,:,alpha))
   end do
   
   ! loop over chains
   do i_chain = 1, N_chain
     call chain_density(i_chain,chains(i_chain),omega_grid)
     if(present(qout)) qout(i_chain) = chains(i_chain)%bigQ
   end do
  
   ! takes into account solvent monomer densities
   rho_grid = 0.0_long
   do i=1, N_solvent
      alpha = solvent_monomer(i)
      Ns  = solvent_size(i)   ! = solvent volume / reference volume
      CALL solvent_density(alpha,Ns,omega_grid,rho_grid,bigQ_solvent)
      if(present(q_solvent)) q_solvent(i) = bigQ_solvent
   end do
  
   if (ensemble ==1) then 
      if (present(qout)) then
         call mu_phi_chain(mu_chain,phi_chain,qout)
      end if
      if (present(q_solvent)) then
         call mu_phi_solvent(mu_solvent,phi_solvent,q_solvent)
      end if
   end if
 
   ! calculate monomer densities
   do i_chain = 1, N_chain
     do i_blk = 1, N_block(i_chain)
         alpha = block_monomer(i_blk,i_chain)
         rho_grid(:,:,:,alpha) = rho_grid(:,:,:,alpha) &
             + phi_chain(i_chain) * chains(i_chain)%rho(:,:,:,i_blk)
     end do
   end do
  
   ! project monomer densities onto basis functions
   do alpha=1, N_monomer
     call fft(plan,rho_grid(:,:,:,alpha),kgrid)
     call kgrid_to_basis(kgrid,rho(alpha,:))
     rho(alpha,:)=rho(alpha,:)/rnodes
   end do

   if( allocated(kgrid) ) deallocate(kgrid)

   end subroutine density
   !=======================================================
  

   !--------------------------------------------------------------------------
   !****p scf_mod/solvent_density
   ! SUBROUTINE 
   !    solvent_density(monomer,s_size,omega,rho_grid,bigQ_solvent)
   !
   ! PURPOSE
   !    to calculate the density profile of a  solvent specie
   !
   ! ARGUMENTS
   !    monomer      - monomer type of the solvent species
   !    s_size       - volume occupied by solvent molecule / reference volume
   !                   (volume in units where reference volume = 1)
   !    omega        - omega fields on grid, per reference volume
   !    rho_grid     - density fields on grid    
   !    bigQ_solvent - spatial average of Boltzmann factor exp(-s_size*omega)
   !
   ! SOURCE
   !--------------------------------------------------------------------------
   subroutine solvent_density(monomer,s_size,omega,rho_grid,bigQ_solvent)
   implicit none
   
   real(long),intent(IN)              :: s_size
   real(long),intent(IN)              :: omega(0:,0:,0:,:)
   integer,intent(IN)                 :: monomer
   real(long),intent(INOUT)           :: rho_grid(0:,0:,0:,:)
   real(long),intent(OUT)             :: bigQ_solvent          
   !***
   
   real(long):: rnodes

   integer   :: ix,iy,iz,i    ! loop indices
   integer   :: solvent       ! solvent species index in phi array
   integer   :: error
 
   rnodes = dble(ngrid(1) * ngrid(2) * ngrid(3))
  
   ! calculating bigQ_solvent
   bigQ_solvent = 0.0_long  
   do iz=0, ngrid(3)-1 
      do iy=0, ngrid(2)-1
         do ix=0, ngrid(1)-1
            
            bigQ_solvent = bigQ_solvent + EXP((-s_size)&
                                              * omega(ix,iy,iz,monomer))
          
         end do
      end do
   end do     

   bigQ_solvent = bigQ_solvent/dble(rnodes)
      
   ! calculating the index of the solvent in the phi array
   do i=1, N_solvent
      if (solvent_monomer(i)==monomer) then
         solvent = i
      end if
      if ( ensemble == 1 )   phi_solvent(solvent) = bigQ_solvent*exp(mu_solvent(solvent))
   end do
 
   rho_grid(:,:,:,monomer) = rho_grid(:,:,:,monomer) + phi_solvent(solvent) * &
                             EXP((-s_size) * omega(:,:,:,monomer))/bigQ_solvent
 
   end subroutine solvent_density
   !====================================================================
  

   !--------------------------------------------------------------------
   !****p scf_mod/chain_density
   ! SUBROUTINE
   !    chain_density(i_chain, chain, omega)
   !
   ! PURPOSE
   !    solve the PDE for a single chain
   !    evaluate the density for each block
   !
   ! ARGUMENTS
   !    i_chain - index to the chain 
   !    chain   - chain_grid_type, see chain_mod
   !    omega   - omega fields on grid
   ! SOURCE   
   !--------------------------------------------------------------------
   subroutine chain_density(i_chain, chain, omega)
   implicit none

   integer,intent(IN)                   :: i_chain
   type(chain_grid_type),intent(INOUT)  :: chain
   real(long),intent(IN)                :: omega(0:,0:,0:,:)
   !***

   integer       :: chain_end, i_blk
   integer       :: istep, ibgn, iend
   real(long)    :: ds, b
   integer       :: i, j, k,l,m,monomer
   integer       :: ix, iy, iz
   integer       :: bgn, lst
   character(20) :: blk_type,previous_blk_type,next_blk_type
   real(long)    :: rho_uint   
   real(long)    :: twopi 

   twopi = 4.0_long*acos(0.0_long)

   ! Calculate qf, by integratin forward from s=0
   ! Initialize propagator
   select case (block_type(1,i_chain))
   case ('Gaussian')
      chain%qf(:,:,:,1) = 1.0_long 
   case ('Wormlike')
      chain%qwf(:,:,:,:,1) = 1.0_long 
      call qw_decompose(chain%qwf(:,:,:,:,1),chain%qwj(:,:,:,:,1),1)
   case default
      stop 'Invalid type of block' 
   end select

   ! loop over blocks 
   do i_blk = 1, N_block(i_chain)
      blk_type = block_type(i_blk, i_chain) 
      monomer  = block_monomer(i_blk, i_chain)
      ds       = chain%block_ds(i_blk)
      b        = kuhn( monomer )
      bgn      = chain%block_bgn_lst(1,i_blk)
      lst      = chain%block_bgn_lst(2,i_blk)

      select case (blk_type)
      case('Gaussian')
         call make_propg(ds, b, omega(:,:,:,monomer))

         do istep = bgn, lst-1 
            call step_gaussian(chain%qf(:,:,:,istep), &
                               chain%qf(:,:,:,istep+1), chain%plan)
         end do

         if (i_blk < N_block(i_chain)) then
            next_blk_type = block_type(i_blk+1,i_chain) 
            if (next_blk_type=='Wormlike') then 
               do l=0,N_sph-1
                  chain%qwf(:,:,:,l,chain%block_bgn_lst(1,i_blk+1)) = chain%qf(:,:,:,lst) 
               enddo 
               call qw_decompose(chain%qwf(:,:,:,:,chain%block_bgn_lst(1,i_blk+1)),&
                                 chain%qwj(:,:,:,:,chain%block_bgn_lst(1,i_blk+1)),1 )
            else
               chain%qf(:,:,:,chain%block_bgn_lst(1,i_blk+1)) = chain%qf(:,:,:,lst)
            endif
         endif

      case('Wormlike')
         call make_propg(ds, b, omega(:,:,:,monomer),Index_worm_block(i_blk,i_chain),1)

         if (lst-bgn < 4) stop "Step size is too large!"
         ! update first and second steps by euler method 
         do istep = 0,1
            call step_wormlike_euler(chain%qwj(:,:,:,:,bgn+istep)  ,  & 
                                     chain%qwj(:,:,:,:,bgn+istep+1),  &
                                     chain%qwf(:,:,:,:,bgn+istep+1),  &
                                     chain%plan_many,1)
         end do 
         bgn = bgn + 2

         ! update the rest steps by BDF3 
         do istep = bgn, lst-1
            call step_wormlike_bdf3(chain%qwj(:,:,:,:,istep-2),  &
                                    chain%qwj(:,:,:,:,istep-1),  &
                                    chain%qwj(:,:,:,:,istep  ),  &
                                    chain%qwj(:,:,:,:,istep+1),  &
                                    chain%qwf(:,:,:,:,istep+1),  &
                                    chain%plan_many,1) 
         enddo 

         if (i_blk < N_block(i_chain)) then
            next_blk_type = block_type(i_blk+1,i_chain) 
            if(next_blk_type=='Gaussian') then
               !$OMP PARALLEL DO COLLAPSE(3)
               do i=0,ngrid(1)-1
               do j=0,ngrid(2)-1
               do k=0,ngrid(3)-1
               chain%qf(i,j,k,chain%block_bgn_lst(1,i_blk+1)) = & 
                  dot_product(chain%qwf(i,j,k,:,lst),angularf_grid(3,:)) /(2.0_long*twopi)
               enddo 
               enddo 
               enddo 
               !$OMP END PARALLEL DO 
            else 
               chain%qwj(:,:,:,:,chain%block_bgn_lst(1,i_blk+1)) = chain%qwj(:,:,:,:,lst) 
               chain%qwf(:,:,:,:,chain%block_bgn_lst(1,i_blk+1)) = chain%qwf(:,:,:,:,lst) 
            endif
         endif

      case default
         stop 'Invalid type of block' 
      end select

   end do

   ! Calculate qr, by integrating backward from s = chain_end
   chain_end = chain%block_bgn_lst(2,N_block(i_chain)) 
   select case (block_type(N_block(i_chain),i_chain))
   case ('Gaussian')
      chain%qr(:,:,:,chain_end) = 1.0_long 
   case ('Wormlike')
      chain%qwr(:,:,:,:,chain_end) = 1.0_long 
      call qw_decompose(chain%qwr(:,:,:,:,chain_end),chain%qwj(:,:,:,:,chain_end),-1) 
   case default
      stop 'Invalid type of block' 
   end select
   
   do i_blk = N_block(i_chain), 1, -1
      blk_type = block_type(i_blk,i_chain)
      monomer = block_monomer(i_blk,i_chain)
      ds = chain%block_ds(i_blk)
      b  = kuhn( monomer )
      bgn = chain%block_bgn_lst(1,i_blk) 
      lst = chain%block_bgn_lst(2,i_blk) 

      select case (blk_type)
      case('Gaussian')
         call make_propg(ds, b, omega(:,:,:,monomer) )

         ! initial condition
         if (i_blk < N_block(i_chain)) then
            previous_blk_type = block_type(i_blk+1,i_chain) 
            if(previous_blk_type=='Gaussian') then
               chain%qr(:,:,:,lst) = chain%qr(:,:,:,chain%block_bgn_lst(1,i_blk+1)) 
            elseif (previous_blk_type=='Wormlike') then 
               !$OMP PARALLEL DO COLLAPSE(3)
               do i=0,ngrid(1)-1
               do j=0,ngrid(2)-1
               do k=0,ngrid(3)-1
                  chain%qr(i,j,k,lst) = &
                     dot_product(chain%qwr(i,j,k,:,chain%block_bgn_lst(1,i_blk+1)),angularr_grid(3,:))/(2.0_long*twopi) 
               enddo
               enddo
               enddo
               !$OMP END PARALLEL DO 
            endif
         endif
         
         ! integrating
         do istep = lst, bgn+1, -1 
            call step_gaussian(chain%qr(:,:,:,istep)  , &
                               chain%qr(:,:,:,istep-1), chain%plan)
         end do

      case('Wormlike')
         call make_propg(ds, b, omega(:,:,:,monomer),Index_worm_block(i_blk,i_chain),-1)

         if (lst-bgn < 4) stop "Step size is too large! Why?"
         ! last step is 
         if (i_blk < N_block(i_chain)) then
            previous_blk_type = block_type(i_blk+1,i_chain) 
            if(previous_blk_type=='Gaussian') then
               !$OMP PARALLEL DO 
               do l=0,N_sph-1
               chain%qwr(:,:,:,l,lst) = &
                                chain%qr(:,:,:,chain%block_bgn_lst(1,i_blk+1))
               enddo 
               !$OMP END PARALLEL DO 
               call qw_decompose(chain%qwr(:,:,:,:,lst),chain%qwj(:,:,:,:,lst),-1)
            elseif (previous_blk_type=='Wormlike') then 
               chain%qwr(:,:,:,:,lst) = chain%qwr(:,:,:,:,chain%block_bgn_lst(1,i_blk+1))
               chain%qwj(:,:,:,:,lst) = chain%qwj(:,:,:,:,chain%block_bgn_lst(1,i_blk+1))

            endif
         endif

         ! update first and second steps by euler method 
         do istep = 0,1
            call step_wormlike_euler(chain%qwj(:,:,:,:,lst-istep)  ,&
                                     chain%qwj(:,:,:,:,lst-istep-1),&
                                     chain%qwr(:,:,:,:,lst-istep-1),&
                                     chain%plan_many,-1)
         end do 
         lst = lst -2 

         ! update the rest steps by BDF3 
         do istep = lst, bgn+1, -1
            call step_wormlike_bdf3(chain%qwj(:,:,:,:,istep+2), &
                                    chain%qwj(:,:,:,:,istep+1), &
                                    chain%qwj(:,:,:,:,istep  ), &
                                    chain%qwj(:,:,:,:,istep-1), &
                                    chain%qwr(:,:,:,:,istep-1), &
                                    chain%plan_many,-1) 
         enddo 


      case default
         stop 'Invalid type of block' 
      end select

   end do

   ! Calculate single chain partition function chain%bigQ
   chain_end = chain%block_bgn_lst(2,N_block(i_chain))
   if (block_type(N_block(i_chain),i_chain) == 'Wormlike') then 
      !$OMP PARALLEL DO COLLAPSE(3)
      do i=0,ngrid(1)-1
      do j=0,ngrid(2)-1
      do k=0,ngrid(3)-1
      q0(i,j,k) = dot_product(chain%qwf(i,j,k,:,chain_end),angularf_grid(3,:) )
      enddo
      enddo
      enddo
      !$OMP END PARALLEL DO 
      chain%bigQ = sum(q0) / ( 2.0_long*twopi*dble(size(q0)) ) 
   elseif (block_type(N_block(i_chain),i_chain) == 'Gaussian') then 
      ! pure gaussian chain  
      chain%bigQ = sum(chain%qf(:,:,:,chain_end)) &
          / dble(size(chain%qf(:,:,:,chain_end)))
   endif


   !if (chain%block_exist(2)) then 
   !   ! if wormlike block exist 
   !   do i_blk = N_block(i_chain),1,-1
   !      if (block_type(i_blk,i_chain)=='Wormlike') then 
   !         chain_end = chain%block_bgn_lst(2,i_blk) 
   !      endif
   !   enddo

   !   !$OMP PARALLEL DO COLLAPSE(3)
   !   do i=0,ngrid(1)-1
   !   do j=0,ngrid(2)-1
   !   do k=0,ngrid(3)-1
   !   q0(i,j,k) = dot_product(chain%qwf(i,j,k,:,chain_end),angular_grid(3,:) )
   !   enddo
   !   enddo
   !   enddo
   !   !$OMP END PARALLEL DO 
   !   chain%bigQ = sum(q0) / ( 2.0_long*twopi*dble(size(q0)) ) 
   !else
   !   chain_end = chain%block_bgn_lst(2,N_block(i_chain)) 
   !   ! pure gaussian chain  
   !   chain%bigQ = sum(chain%qf(:,:,:,chain_end)) &
   !       / dble(size(chain%qf(:,:,:,chain_end)))
   !endif


   ! Calculate monomer concentration fields, using Simpson's rule
   ! to evaluate the integral \int ds qr(r,s)*qf(r,s)
   chain%rho = 0.0_long
   do i = 1, N_block(i_chain)
      ibgn=chain%block_bgn_lst(1,i)
      iend=chain%block_bgn_lst(2,i)
      blk_type = block_type(i,i_chain)  

      select case (blk_type)
      case ('Gaussian') 
         call rho_field(chain%block_ds(i), chain%qf(:,:,:,ibgn:iend),chain%qr(:,:,:,ibgn:iend),chain%rho(:,:,:,i))               
      case ('Wormlike')
         call rho_field(chain%block_ds(i), chain%qwf(:,:,:,:,ibgn:iend),chain%qwr(:,:,:,:,ibgn:iend),chain%rho(:,:,:,i))               
      case default
         stop 'Invalid type of block'
      end select 
   end do

   chain%rho=chain%rho/chain_length(i_chain)/chain%bigQ

   end subroutine chain_density
   !====================================================================

   !--------------------------------------------------------------------
   !****p scf_mod/scf_stress
   ! FUNCTION
   !    scf_stress(N, size_dGsq, dGsq )
   !
   ! RETURN
   !    real(long) array of dimension(size_dGsq) containing
   !    derivatives of free energy with respect to size_dGsq 
   !    cell parameters or deformations
   !
   ! ARGUMENTS
   !    N         = number of basis functions
   !    size_dGsq = number of cell parameters or deformations
   !    dGsq      = derivatives of |G|^2 w.r.t. cell parameters
   !                dGsq(i,j) = d |G(i)|**2 / d cell_param(j)
   ! COMMENT
   !    Requires previous call to density, because scf_stress
   !    uses module variables computed in density.
   !
   ! SOURCE
   !--------------------------------------------------------------------
   function scf_stress(N, size_dGsq, dGsq )
   implicit none

   integer,    intent(IN) :: N
   integer,    intent(IN) :: size_dGsq
   real(long), intent(IN) :: dGsq(:,:)
   !***

   real(long)  :: scf_stress(size_dGsq)

   ! ngrid(3) was obtained by association
   ! Local Variables

   real(long)      :: dQ(size_dGsq)    ! change in q
   real(long)      :: qf_basis(N),qr_basis(N),q_swp(N)
   !complex(long)   :: kgrid(0:ngrid(1)/2,0:ngrid(2)-1,0:ngrid(3)-1)
   complex(long),allocatable   :: kgrid(:,:,:)

   real(long)      :: rnodes, normal
   real(long)      :: ds0, ds, b
   real(long)      :: increment
   integer         :: i, alpha, beta   ! summation indices
   integer         :: monomer             ! monomer index
   integer         :: sp_index            ! species index
   integer         :: ibgn,iend
   integer         :: info
   integer         :: j,k,l

   allocate( kgrid(0:ngrid(1)/2, 0:ngrid(2)-1, 0:ngrid(3)-1), stat=info )
   if ( info /= 0 ) stop "scf_mod/scf_stress/kgrid(:,:,:) allocation error"

   ! number of grid points
   rnodes = dble( ngrid(1) * ngrid(2) * ngrid(3) )

   ! normal = rnodes  * &! normalization of bigQ, divided by volume
   normal = rnodes   *  &! fft normal of forward partition
            rnodes   *  &! fft normal of backward partition
            3.0_long *  &! normal simpson's rule
            6.0_long     ! b**2/6

   scf_stress = 0.0_long

   ! Loop over chain species
   do sp_index = 1, N_chain
      dQ = 0.0_long

      ! Loop over blocks
      do alpha = 1,  N_block(sp_index) 
         monomer = block_monomer(alpha,sp_index)
               b = kuhn(monomer)
             ds0 = chains(sp_index)%block_ds(alpha)

            ibgn = chains(sp_index)%block_bgn_lst(1,alpha)
            iend = chains(sp_index)%block_bgn_lst(2,alpha)

         do i = ibgn, iend
            if (block_type(alpha, sp_index)=='Gaussian') then
               q0  = chains(sp_index)%qf(:,:,:,i) 
               qr0 = chains(sp_index)%qr(:,:,:,i) 
            elseif (block_type(alpha, sp_index) =='Wormlike') then

               do j=0,ngrid(1)-1
               do k=0,ngrid(2)-1
               do l=0,ngrid(3)-1
               q0(j,k,l) = dot_product(chains(sp_index)%qwf(j,k,l,:,i), angularf_grid(3,:)) 
               enddo
               enddo
               enddo
               q0 = q0 / (8.0_long*acos(0.0_long)) 

               do j=0,ngrid(1)-1
               do k=0,ngrid(2)-1
               do l=0,ngrid(3)-1
               qr0(j,k,l) = dot_product(chains(sp_index)%qwr(j,k,l,:,i), angularr_grid(3,:)) 
               enddo
               enddo
               enddo
               qr0 = qr0 / (8.0_long*acos(0.0_long)) 

            else
               stop 'Invalid type of block in scf_stress.'
            endif 

            ! rgrid=dcmplx( chains(sp_index)%qf(:,:,:,i), 0.0_long)
            call fft(plan, q0, kgrid )
            call kgrid_to_basis( kgrid, qf_basis )

            ! rgrid=dcmplx( chains(sp_index)%qr(:,:,:,i), 0.0_long)
            call fft(plan, qr0, kgrid )
            call kgrid_to_basis( kgrid, qr_basis )

            ds = ds0
            if ( i/= ibgn .and. i/= iend) then
               if (modulo(i-ibgn+1,2) == 0) then
                  ds = 4.0_long * ds
               else
                  ds = 2.0_long * ds
               end if
            end if   ! Simpson's rule quadrature

            do beta = 1, size_dGsq
               q_swp     = qr_basis * dGsq(:,beta)
               increment = dot_product(q_swp, qf_basis)
               increment = increment * b**2 * ds / normal
               dQ(beta)  = dQ(beta) - increment
            end do

         end do      ! loop over nodes of single block
      end do         ! loop over blocks


      ! Note the mixing rule
      ! stress(total) = \sum_alpha \phi_alpha \cdot~stress(\alpha)
      select case(ensemble)
      case (0)
         scf_stress = scf_stress - (dQ / chains(sp_index)%bigQ)*  &
                      phi_chain(sp_index)/chain_length(sp_index)
      case (1)
         scf_stress = scf_stress - (dQ / chains(sp_index)%bigQ)*  &
                      exp(mu_chain(sp_index))*chains(sp_index)%bigQ  / &
                      chain_length(sp_index)
      end select

   end do

   if ( allocated(kgrid) ) deallocate( kgrid )

   end function scf_stress
   !===================================================================


   !# ifdef DEVEL
   !-------------------------------------------------------------------
   !****p scf_mod/divide_energy
   ! SUBROUTINE
   !    divide_energy(rho, omega, phi_chain, phi_solvent, Q, f_comp, ovlap)
   ! PURPOSE   
   !    Divide free energy into components arising from binary
   !    interaction free energy and from chain entropy
   ! ARGUMENTS
   !    rho         = density fields
   !  omega         = potential fields
   !    phi_chain  = volume fraction of species (chain)
   !    phi_solvent = volume fraction of species (solvent)
   !      Q         = partion function of species (chain)
   !  f_tot         = total free energy
   ! f_comp         = components of free energy (see below)
   !  ovlap         = overlap integrals
   ! COMMENT
   !
   !    a) Components of f_comp array:
   !       f_comp(1) = overall interaction energy
   !       f_comp(2) = conformational energy of first block
   !       f_comp(3) = conformational energy of last  block
   !       f_comp(4) = junction translational energy (diblock)
   !
   !    b) Calculation of junction translational entropy is correct
   !       only for diblocks, for which there is only one junction
   !
   !    c) Components of overlap integral array ovlap can be used
   !       to divide interaction energy into components arising from
   !       interactions between specific pairs of monomer types.
   !
   ! SOURCE
   !----------------------------------------------------------------
   subroutine divide_energy(rho, omega, phi_chain, phi_solvent, Q, f_tot, f_comp, ovlap)
   implicit none
   real(long), intent(IN)  :: rho(:,:)        ! monomer vol. frac fields
   real(long), intent(IN)  :: omega(:,:)      ! chemical potential field
   real(long), intent(IN)  :: phi_chain(:)    ! molecule vol. frac of chain mol
   real(long), intent(IN)  :: phi_solvent(:)  ! molecule vol. frac of solvent mol
   real(long), intent(IN)  :: Q(:)            ! chain partition functions
   real(long), intent(IN)  :: f_tot           ! components of free energy
   real(long), intent(OUT) :: f_comp(:)       ! components of free energy
   real(long), intent(OUT) :: ovlap(:,:)      ! overlap integrals,N_monomer**2
   !***

   real(long) :: rnodes
   real(long) :: enthalpy    ! interaction energy
   real(long) :: fhead       ! head block energy
   real(long) :: ftail       ! tail block energy
   real(long) :: fjct        ! junction translational entropy
   real(long) :: ftmp        ! junction translational entropy (temporary)
   integer    :: alpha, beta ! monomer indices
   integer    :: i, nh, nt   ! loop indices
   integer    :: ix,iy,iz    ! loop indices

   rnodes = dble( ngrid(1) * ngrid(2) * ngrid(3) )

   enthalpy = 0.0_long
   ovlap    = 0.0_long
   do alpha = 1, N_monomer
      do beta = alpha+1, N_monomer
         ovlap(alpha,beta) = dot_product(rho(alpha,:),rho(beta,:))
         ovlap(beta,alpha) = ovlap(alpha,beta)
         enthalpy = enthalpy + chi(alpha,beta) * ovlap(alpha,beta)
      end do
   end do

   fhead = 0.0_long
   ftail = 0.0_long
   do i=1, N_chain
      nh = chains(i)%block_bgn_lst(1,2)
      do iz = 0, ngrid(3)-1
      do iy = 0, ngrid(2)-1
      do ix = 0, ngrid(1)-1
         if ( chains(i)%qf(ix,iy,iz,nh) > 0.0_long .AND. &
              chains(i)%qr(ix,iy,iz,nh) > 0.0_long ) then
            fhead = fhead - chains(i)%qf(ix,iy,iz,nh)   &
                          * chains(i)%qr(ix,iy,iz,nh)   &
                          / Q(i)                        &
                          * log( chains(i)%qf(ix,iy,iz,nh) ) & 
                          * phi_chain(i) / chain_length(i)
         end if
      end do
      end do
      end do

      nt = chains(i)%block_bgn_lst(1,N_block(i))
      do iz = 0, ngrid(3)-1
      do iy = 0, ngrid(2)-1
      do ix = 0, ngrid(1)-1
         if ( chains(i)%qf(ix,iy,iz,nt) > 0.0_long .AND. &
              chains(i)%qr(ix,iy,iz,nt) > 0.0_long ) then
            ftail = ftail - chains(i)%qf(ix,iy,iz,nt)   &
                          * chains(i)%qr(ix,iy,iz,nt)   &
                          / Q(i)                        &
                          * log( chains(i)%qr(ix,iy,iz,nt) ) &
                          * phi_chain(i) / chain_length(i)
         end if
      end do
      end do
      end do
   end do
   fhead = fhead / rnodes
   ftail = ftail / rnodes

   ! When monomer types in the middle blocks are different from either
   ! head or tail block, the subtraction below is correct.
   do i=1, N_chain
      beta=block_monomer(1,i)
      fhead = fhead - dot_product(omega(beta,:),rho(beta,:)) * phi_chain(i)

      beta=block_monomer(N_block(i),i)
      ftail = ftail - dot_product(omega(beta,:),rho(beta,:)) * phi_chain(i)
   end do

   ! --------------------------------------------
   ! The following block was used to calculate
   ! junction entropy contribution to free
   ! energy of diblocks. 
   ! Since it is not universal, we now instead
   ! calculate by subtraction, which can be
   ! interpreted by excess entropies for arbitrary
   ! molecular (linear) architecture.
   ! --------------------------------------------
   !## fjct = 0.0_long
   !## do i=1, N_chain
   !##    nh = chains(i)%block_bgn(2)
   !##    do iz = 0, ngrid(3)-1
   !##    do iy = 0, ngrid(2)-1
   !##    do ix = 0, ngrid(1)-1
   !##       if ( chains(i)%qf(ix,iy,iz,nh) > 0.0_long .AND. &
   !##            chains(i)%qr(ix,iy,iz,nh) > 0.0_long ) then
   !##          ftmp  = chains(i)%qf(ix,iy,iz,nh) &
   !##                * chains(i)%qr(ix,iy,iz,nh) &
   !##                / Q(i) 
   !##          fjct = fjct + ftmp * log( ftmp ) * phi_chain(i) / chain_length(i)
   !##       end if
   !##    end do
   !##    end do
   !##    end do
   !## end do
   !## fjct  = fjct  / rnodes
   ! --------------------------------------------
   fjct = 0.0_long
   do i=1, N_chain
      fjct = fjct + phi_chain(i) / chain_length(i)
   end do
   fjct = f_tot + fjct - enthalpy - fhead - ftail

   f_comp(1) = enthalpy   ! overall interaction energy
   f_comp(2) = fhead      ! conformational energy of first block
   f_comp(3) = ftail      ! conformational energy of last  block
   f_comp(4) = fjct       ! junction translational energy (diblock)

   end subroutine divide_energy
   !=============================================================
   !# endif


   !------------------------------------------------------------
   !****p scf_mod/set_omega_uniform
   ! SUBROUTINE
   !    set_omega_uniform(omega)
   ! PURPOSE
   !   Sets uniform (k=0) component of field omega to convention
   !      omega(:,1) = chi(:,:) .dot. phi_mon(:)
   !   corresponding to vanishing Lagrange multiplier field
   ! SOURCE
   !------------------------------------------------------------
   subroutine set_omega_uniform(omega)
   real(long), intent(INOUT) :: omega(:,:)
   !***

   integer    :: i, j, alpha, beta  ! loop indices
   real(long) :: phi_mon(N_monomer) ! average monomer vol. frac.

   phi_mon = 0.0_long
   do i = 1, N_chain
      do j = 1, N_block(i)
         alpha = block_monomer(j,i)
         phi_mon(alpha) = phi_mon(alpha) &
                        + phi_chain(i)*block_length(j,i)/chain_length(i)
      end do
   end do
   do i = 1, N_solvent
      alpha = solvent_monomer(i)
      phi_mon(alpha) = phi_mon(alpha) + phi_solvent(i)
   end do
   do alpha = 1, N_monomer
      omega(alpha,1) = 0.0_long
      do beta = 1, N_monomer
         omega(alpha,1) = omega(alpha,1) &
              + chi(alpha,beta) * phi_mon(beta)
      end do
   end do
   end subroutine set_omega_uniform
   !================================================================


   !-------------------------------------------------------------
   !****p scf_mod/mu_phi_chain
   ! SUBROUTINE
   !    mu_phi_chain(mu, phi, q)
   ! PURPOSE
   !    If ensemble = 0 (canonical), calculate mu from phi
   !    If ensemble = 1 (grand), calculate phi from mu
   ! ARGUMENTS
   !    mu(N_chain)  = chain chemical potentials (units kT=1)
   !    phi(N_chain) = chain molecular volume fractions 
   !    q(N_chain)   = single chain partition functions
   !
   ! SOURCE
   !-------------------------------------------------------------
   subroutine mu_phi_chain(mu, phi, q)
   real(long), intent(INOUT) :: mu(N_chain)
   real(long), intent(INOUT) :: phi(N_chain) 
   real(long), intent(IN)    :: q(N_chain)
   !***

   integer :: i
   select case(ensemble)
   case (0)
      do i = 1, N_chain
         mu(i) = log( phi(i) / q(i) )
      end do
   case (1)
      do i = 1, N_chain
         phi(i) = q(i)*exp(mu(i))
      end do
   end select
   end subroutine mu_phi_chain
   !================================================================


   !-------------------------------------------------------------
   !****p scf_mod/mu_phi_solvent
   ! SUBROUTINE
   !    mu_phi_solvent(mu, phi, q)
   ! PURPOSE
   !    If ensemble = 0 (canonical), calculate mu from phi
   !    If ensemble = 1 (grand can), calculate phi from mu
   ! ARGUMENTS
   !    mu(N_solvent)  = solvent chemical potentials 
   !    phi(N_solvent) = solvent volume fractions
   !    q(N_solvent)   = solvent partition functions
   !
   ! SOURCE
   !-------------------------------------------------------------
   subroutine mu_phi_solvent(mu, phi, q)
   real(long), intent(INOUT) :: mu(N_solvent)
   real(long), intent(INOUT) :: phi(N_solvent)
   real(long), intent(IN)    :: q(N_solvent) 
   !***

   integer :: i
   select case(ensemble)
   case (0)
      do i = 1, N_solvent
         mu(i) = log(phi(i) / q(i))  
      end do
   case (1)
      do i = 1, N_solvent
         phi(i) = q(i)*exp(mu(i))
      end do
   end select
   end subroutine mu_phi_solvent
   !================================================================


   !--------------------------------------------------------------------
   !****p scf_mod/free_energy
   ! SUBROUTINE
   !    free_energy( N, rho, omega, phi_chain, mu_chain, phi_solvent,
   !                 mu_solvent, f_Helmholtz, [pressure] )
   ! PURPOSE   
   !    Calculates Helmholtz free energy / monomer and (optionally)
   !    the pressure, given phi, mu, and omega and rho fields
   ! SOURCE
   !--------------------------------------------------------------------
   subroutine free_energy(N, rho, omega, phi_chain, mu_chain, &
                          phi_solvent, mu_solvent, f_Helmholtz, pressure )
   integer, intent(IN)    :: N              ! # of basis functions
   real(long), intent(IN) :: rho(:,:)       ! monomer vol. frac fields
   real(long), intent(IN) :: omega(:,:)     ! chemical potential field
   real(long), intent(IN) :: phi_chain(:)   ! molecule vol. frac of chain species
   real(long), intent(IN) :: mu_chain(:)    ! chemical potential of chain species
   real(long), intent(IN) :: phi_solvent(:) ! molecule vol. fraction of solvent species 
   real(long), intent(IN) :: mu_solvent(:)  ! chemical potential of solvent species
   real(long), intent(OUT):: f_Helmholtz    ! free energy/monomer
   real(long), intent(OUT), optional :: pressure 
   !***
 
   integer :: i, alpha, beta ! loop indices

   f_Helmholtz = 0.0_long
   do i = 1, N_chain
      if ( phi_chain(i) > 1.0E-8 ) then
         f_Helmholtz = f_Helmholtz &
                     + phi_chain(i)*( mu_chain(i) - 1.0_long )/chain_length(i)
      end if
   end do
   do i=1, N_solvent
      if ( phi_solvent(i) > 1.0E-8) then
         f_Helmholtz = f_Helmholtz &
                     + phi_solvent(i)*( mu_solvent(i) - 1.0_long)/solvent_size(i)
      end if
   end do
   do i = 1, N
      do alpha = 1, N_monomer
         do beta = alpha+1, N_monomer
            f_Helmholtz = f_Helmholtz &
                        + rho(alpha,i)*chi(alpha,beta)*rho(beta,i)
         end do
         f_Helmholtz = f_Helmholtz - omega(alpha,i) * rho(alpha,i)
      end do
   end do
   
   if (present(pressure)) then
      pressure = -f_Helmholtz
      do i = 1, N_chain
         pressure = pressure + mu_chain(i)*phi_chain(i)/chain_length(i)
      end do
      do i = 1, N_solvent
         pressure = pressure + mu_solvent(i)*phi_solvent(i)/solvent_size(i)
      end do
   end if
 
   end subroutine free_energy
   !====================================================================


   !--------------------------------------------------------------------
   !****p scf_mod/free_energy_FH
   ! FUNCTION
   !    real(long) function free_energy_FH(phi_chain,phi_solvent)
   ! RETURN
   !    Flory-Huggins Helmholtz free energy per monomer, in units
   !    such that kT =1, for a homogeneous mixture of the specified 
   !    composition.
   ! ARGUMENTS
   !    phi_chain(N_chain)     = molecular volume fractions of chains
   !    phi_solvent(N_solvent) = molecular volume fractions of solvents
   ! SOURCE
   !--------------------------------------------------------------------
   real(long) function free_energy_FH(phi_chain,phi_solvent)
   real(long), intent(IN)           :: phi_chain(N_chain)
   real(long), intent(IN), optional :: phi_solvent(N_solvent)

   real(long)             :: rho(N_monomer)
   !***
   integer :: i, j, i_block, i_mon
   free_energy_FH = 0.0_long
   rho = 0.0_long

   do i = 1, N_chain
      if ( phi_chain(i) > 1.0E-8 ) then
           free_energy_FH = free_energy_FH + & 
                            (phi_chain(i)/chain_length(i))*(log(phi_chain(i))-1)
      end if
      do i_block = 1, N_block(i)
         i_mon = block_monomer(i_block,i)
         rho(i_mon) = rho(i_mon) & 
                    + phi_chain(i)*block_length(i_block,i)/chain_length(i)
      end do
   end do

   if (present(phi_solvent)) then
      do i=1, N_solvent
         if ( phi_solvent(i) > 1.0E-8 ) then
              free_energy_FH = free_energy_FH + &
                         (phi_solvent(i)/solvent_size(i))*(log(phi_solvent(i))-1)
         end if
         i_mon = solvent_monomer(i)
         rho(i_mon) = rho(i_mon) + phi_solvent(i)
      end do
   end if

   do i = 1, N_monomer - 1
      do j = i+1, N_monomer
         free_energy_FH = free_energy_FH + chi(i,j)*rho(i)*rho(j)
      end do
   end do
   end function free_energy_FH
   !=============================================================

   !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
   ! Definitions of rho_field
   !%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

   !--------------------------------------------------------------------
   !****p scf_mod/rho_field
   ! FUNCTION
   !    rho_field(ds, qf_in, qr_in, rho_out )
   !
   ! RETURN 
   !    real(long) array of dimension(x,y,z,nblk) containing 
   !    the density of ith monomer  
   ! ARGUMENTS
   !       ds  : step size in s 
   !    qf_in  : forward propagator 
   !    qr_in  : backward propagator 
   !    rho_field: density of ith monomer  
   ! COMMENT
   !     
   ! SOURCE
   !--------------------------------------------------------------------
   subroutine rho_field_gaussian(ds, qf_in,qr_in,rho_out)
   implicit none 
   real(long), intent(IN) :: ds 
   real(long), intent(IN) :: qf_in(0:,0:,0:,1:) 
   real(long), intent(IN) :: qr_in(0:,0:,0:,1:) 
   real(long), intent(OUT):: rho_out(0:,0:,0:) 

   integer      :: iz,iy,ix,j   !looping variables 
   integer      :: ibgn, iend   !index of the first and last segment
   !*** 
 
   ibgn = 1                 ! first index 
   iend = size(qf_in,4)     ! last  index 

   rho_out = 0.0_long 
   !$OMP PARALLEL DO COLLAPSE(3)
   do iz=0,ngrid(3)-1
   do iy=0,ngrid(2)-1
   do ix=0,ngrid(1)-1
      rho_out(ix,iy,iz)=qf_in(ix,iy,iz,ibgn)*qr_in(ix,iy,iz,ibgn)
   end do
   end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO COLLAPSE(3)
   do iz=0,ngrid(3)-1
   do iy=0,ngrid(2)-1
   do ix=0,ngrid(1)-1
      rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                        qf_in(ix,iy,iz,iend)*qr_in(ix,iy,iz,iend)
   end do
   end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO COLLAPSE(4)
   ! Odd indices: Sum values of qf(i)*qr(i)*4.0 with i odd
   do j=ibgn+1,iend-1,2
      do iz=0,ngrid(3)-1
      do iy=0,ngrid(2)-1
      do ix=0,ngrid(1)-1
         rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                           qf_in(ix,iy,iz,j)*qr_in(ix,iy,iz,j)*4.0_long
      end do
      end do
      end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO COLLAPSE(4)
   ! Even indices: Sum values of qf(i)*qr(i)*2.0 with i even
   do j=ibgn+2,iend-2,2
      do iz=0,ngrid(3)-1
      do iy=0,ngrid(2)-1
      do ix=0,ngrid(1)-1
        rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                           qf_in(ix,iy,iz,j)*qr_in(ix,iy,iz,j)*2.0_long
      end do
      end do
      end do
   end do
   !$OMP END PARALLEL DO 

   ! Multiply sum by ds/3
   rho_out=rho_out*ds/3.0_long  
   end subroutine rho_field_gaussian 

   !--------------------------------------------------------------------
   !****p scf_mod/rho_field_wormlike
   ! FUNCTION
   !    rho_field(ds, qf_in, qr_in, rho_out )
   !
   ! RETURN 
   !    real(long) array of dimension(x,y,z,nblk) containing 
   !    the density of ith monomer  
   ! ARGUMENTS
   !       ds  : step size in s 
   !    qf_in  : forward propagator 
   !    qr_in  : backward propagator 
   !    rho_field: density of ith monomer  
   ! COMMENT
   !     
   ! SOURCE
   !--------------------------------------------------------------------

   subroutine rho_field_wormlike(ds,qwf_in,qwr_in,rho_out)
   implicit none 
   real(long), intent(IN) :: ds 
   real(long), intent(IN) :: qwf_in(0:,0:,0:,0:,1:) 
   real(long), intent(IN) :: qwr_in(0:,0:,0:,0:,1:) 
   real(long), intent(OUT):: rho_out(0:,0:,0:) 

   integer      :: iz,iy,ix,j,l !looping variables 
   integer      :: ibgn, iend !index of the first and last segment
   real(long)   :: fourpi
   real(long)   :: qwfr_product(0:N_sph-1) 
   !*** 

   fourpi = 2.0_long*4.0_long*acos(0.0_long) 

   ibgn = 1                  ! first index 
   iend = size(qwf_in,5)     ! last  index 

   rho_out = 0.0_long 
   !$OMP PARALLEL DO collapse(3) private(qwfr_product)
   do iz=0,ngrid(3)-1
   do iy=0,ngrid(2)-1
   do ix=0,ngrid(1)-1
   qwfr_product = qwf_in(ix,iy,iz,:,ibgn)*qwr_in(ix,iy,iz,:,ibgn)
   rho_out(ix,iy,iz)=dot_product(qwfr_product,angularf_grid(3,:)) 
   end do
   end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO collapse(3) private(qwfr_product)
   do iz=0,ngrid(3)-1
   do iy=0,ngrid(2)-1
   do ix=0,ngrid(1)-1
      qwfr_product = qwf_in(ix,iy,iz,:,iend)*qwr_in(ix,iy,iz,:,iend)
      rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                        dot_product(qwfr_product,angularf_grid(3,:)) 
   end do
   end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO collapse(4) private(qwfr_product)
   ! Odd indices: Sum values of qf(i)*qr(i)*4.0 with i odd
   do j=ibgn+1,iend-1,2
      do iz=0,ngrid(3)-1
      do iy=0,ngrid(2)-1
      do ix=0,ngrid(1)-1
         qwfr_product = qwf_in(ix,iy,iz,:,j)*qwr_in(ix,iy,iz,:,j)
         rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                           dot_product(qwfr_product,angularf_grid(3,:))*4.0_long 
      end do
      end do
      end do
   end do
   !$OMP END PARALLEL DO 

   !$OMP PARALLEL DO collapse(4) private(qwfr_product)
   ! Even indices: Sum values of qf(i)*qr(i)*2.0 with i even
   do j=ibgn+2,iend-2,2
      do iz=0,ngrid(3)-1
      do iy=0,ngrid(2)-1
      do ix=0,ngrid(1)-1
        qwfr_product = qwf_in(ix,iy,iz,:,j)*qwr_in(ix,iy,iz,:,j)
        rho_out(ix,iy,iz)=rho_out(ix,iy,iz) + &
                           dot_product(qwfr_product,angularf_grid(3,:))*2.0_long
      end do
      end do
      end do
   end do
   !$OMP END PARALLEL DO 

   ! Multiply sum by ds/3
   rho_out=rho_out*ds/3.0_long/fourpi

   end subroutine rho_field_wormlike 


end module scf_mod
