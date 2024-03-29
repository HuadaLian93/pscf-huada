!-----------------------------------------------------------------------
! PSCF - Polymer Self-Consistent Field Theory
! Copyright (2002-2016) Regents of the University of Minnesota
! contact: David Morse, morse012@umn.edu
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation. A copy of this license is included in
! the LICENSE file in the top-level PSCF directory. 
!-----------------------------------------------------------------------
!****m scf/field_io_mod
! MODULE
!   field_io_mod
! PURPOSE
!   Read and/or write field coeficients to data files. Routines 
!   input_field and output_field read and write representations of a
!   N_monomer component field as a list of coefficients of symetrized
!   basis functions. Routine output_field_grid outputs values of the
!   field on an FFT grid. 
! SOURCE
!-----------------------------------------------------------------------
module field_io_mod
   use const_mod
   use io_mod
   use grid_mod
   use string_mod,     only : int_string
   use version_mod,    only : version_type, input_version, output_version
   use basis_mod,      only : N_star, which_wave, star_of_wave, &
                              wave_of_star, star_count, valid_wave
   use chemistry_mod,  only : N_monomer
   use unit_cell_mod,  only : output_unit_cell, N_cell_param, cell_param
   use fft_mod,        only : fft_plan, create_fft_plan, ifft
   use grid_basis_mod, only : basis_to_kgrid
   implicit none

   private
   public  :: input_field
   public  :: input_Rmatrix
   public  :: input_Ymatrix
   public  :: input_Yinvmatrix
   public  :: output_field
   public  :: output_field_grid
   public  :: output_fields 
   public  :: field_unit 
   !***

   integer, parameter :: field_unit = 22 ! omega and rho fields
contains
   !-------------------------------------------------------------------
   !****p field_io_mod/input_Rmatrix
   ! SUBROUTINE
   !   input_Rmatrix(Rmatrix,Rmatrix_unit)
   ! PURPOSE
   !   Read matrix components from supplied io-unit
   ! ARGUMENTS
   !   matrix_file      =  vector array Rjj
   !
   !   field_unit =  unit number of file to read (open for reading)
   ! SOURCE
   !-------------------------------------------------------------------
   subroutine input_Rmatrix(matrix,matrix_unit)

   real(long),intent(INOUT) :: matrix(1:,0:,0:)  ! (1;3 ,0:N_sph-1, 0:N_sph-1)
   integer,intent(IN)       :: matrix_unit
   !***

   integer            :: i, j                        ! looping varialbes
   integer            :: l,m,lp,mp                   ! index of harmonics , corresponding Rjj vector value         
   real(long)         :: rjj(1:3)                    ! vector at R_jj'
   integer            :: jx_index, jy_index,j_value  ! combined index of (l,m), corresponding value in Rjj                   

   matrix = 0.0_long

   ! 
   DO
      read(matrix_unit,*) l,m,lp,mp,rjj
      jx_index = l**2 + (m +l )
      jy_index = lp**2 + (mp+lp)
      if (jx_index > N_sph-1 .OR. jy_index > N_sph-1) then
         EXIT
      endif 
      matrix(1:3,jx_index,jy_index) = (/rjj(1),rjj(2),rjj(3)/)
      matrix(1:3,jy_index,jx_index) = (/rjj(1),rjj(2),rjj(3)/)
   END DO

   end subroutine input_Rmatrix
   !==============================================================


   !-------------------------------------------------------------------
   !****p field_io_mod/input_Ymatrix
   ! SUBROUTINE
   !   input_Ymatrix(Ymatrix,Ymatrix_unit)
   ! PURPOSE
   !   Read matrix components from supplied io-unit
   ! ARGUMENTS
   !   matrix_file      =  vector array Yj(u)
   !
   !   field_unit =  unit number of file to read (open for reading)
   ! SOURCE
   !-------------------------------------------------------------------
   subroutine input_Ymatrix(matrixf,matrixr,matrix_unit)

   real(long),intent(INOUT) :: matrixf(0:,0:)  ! (0:N_sph-1, 0:N_sph-1)
   real(long),intent(INOUT) :: matrixr(0:,0:)  ! (0:N_sph-1, 0:N_sph-1)

   integer,intent(IN)       :: matrix_unit
   !***

   integer            :: i, j                        ! looping varialbes

   matrixf = 0.0_long
   matrixr = 0.0_long

   do i=0,N_sph-1
   do j=0,N_sph-1
      read(matrix_unit,*) matrixf(j,i)  
   enddo
   enddo

   matrixf = matrixf 
   matrixr = -1.0_long*matrixf

   end subroutine input_Ymatrix
   !==============================================================

   !-------------------------------------------------------------------
   !****p field_io_mod/input_Yinvmatrix
   ! SUBROUTINE
   !   input_Yinvmatrix(Ymatrix,Ymatrix_unit)
   ! PURPOSE
   !   Read matrix components from supplied io-unit
   ! ARGUMENTS
   !   matrix_file      =  vector array Yj(u)
   !
   !   field_unit =  unit number of file to read (open for reading)
   ! SOURCE
   !-------------------------------------------------------------------
   subroutine input_Yinvmatrix(matrixif,matrixir,matrix_unit)

   real(long),intent(INOUT) :: matrixif(0:,0:)  ! (0:N_sph-1, 0:N_sph-1)
   real(long),intent(INOUT) :: matrixir(0:,0:)  ! (0:N_sph-1, 0:N_sph-1)

   integer,intent(IN)       :: matrix_unit
   !***

   integer            :: i, j                        ! looping varialbes

   matrixif = 0.0_long
   matrixir = 0.0_long

   do i=0,N_sph-1
   do j=0,N_sph-1
      read(matrix_unit,*) matrixif(j,i)  
   enddo
   enddo

   matrixif = matrixif 
   matrixir = -1.0_long*matrixif 
   end subroutine input_Yinvmatrix
   !==============================================================

   !-------------------------------------------------------------------
   !****p field_io_mod/input_field
   ! SUBROUTINE
   !   input_field(field,field_unit)
   ! PURPOSE
   !   Read field components from supplied io-unit
   ! ARGUMENTS
   !   field      =  real array containing the coefficients of 
   !                 symmetry-adapted basis functions.
   !   field_unit =  unit number of file to read (open for reading)
   ! SOURCE
   !-------------------------------------------------------------------
   subroutine input_field(field,field_unit)

   real(long),intent(INOUT) :: field(:,:)  ! (monomer,basis_function)
   integer,intent(IN)       :: field_unit
   !***

   integer            :: i, N, G(3), N_arm, i_star
   real(long)         :: swap(N_monomer)
   type(version_type) :: version

   G = 0
   ! Input file format version (e.g., `format 1 0')
   call input_version(version, field_unit)

   ! skip 12 header lines (input_unit_cell, group_name, N_monomer)
   do i=1,12
      read(field_unit,*)
   enddo

   call input(N,'N_star in field file=',i=field_unit)
   field = 0.0_long
   do i = 1, N
      read(field_unit,*) swap,G(1:dim),N_arm
      if ( valid_wave(G) ) then
         i_star = star_of_wave( which_wave(G(1),G(2),G(3)) )
         field(:,i_star) = swap * dsqrt( dble(N_arm) / dble(star_count(i_star)) )
      end if
   end do


   end subroutine input_field
   !==============================================================


   !-------------------------------------------------------------------
   !****p field_io_mod/output_field
   ! SUBROUTINE
   !    output_field(field,field_unit,group_name)
   ! PURPOSE
   !    store coefficients of omega or rho field to supplied io-unit
   ! ARGUMENTS
   !    field       =  field array to store the coefficients
   !    field_unit  =  io-unit for files storing the field coefficients
   !    group_name  =  space group name, supplementary information
   ! SOURCE
   !-------------------------------------------------------------------
   subroutine output_field(field,field_unit,group_name,N_basis_out)

   real(long),  intent(IN)       ::  field(:,:)
   integer,     intent(IN)       ::  field_unit
   character(*),intent(IN)       ::  group_name
   integer,optional,intent(IN)   ::  N_basis_out
   !***

   integer            :: i, N_output
   character(25)      :: fmt
   type(version_type) :: version

   N_output = N_star
   if ( present(N_basis_out) ) N_output = min(N_basis_out, N_star)

   ! Output file format version
   version%major = 1
   version%minor = 0
   call output_version(version, field_unit)

   ! Output unit cell, group_name, N_monomer, and N_star
   call output_unit_cell(field_unit,'F')
   call output(trim(group_name),'group_name',o=field_unit)
   call output(N_monomer,'N_monomer',o=field_unit)
   call output(N_output,'N_star',o=field_unit)


   fmt = '('//trim(int_string(N_monomer))//'ES20.12,4X,'
   fmt = trim(fmt)//trim(int_string(dim))//'I4,I6'//')'
   do i = 1, N_output
      write(field_unit,FMT=trim(fmt)) field(:,i), &
                          wave_of_star(1:dim,i), star_count(i)
   enddo

   end subroutine output_field
   !===============================================================


   !--------------------------------------------------------------   
   !****p field_io_mod/output_field_grid
   ! SUBROUTINE
   !    output_field_grid(field,field_unit,ngrid)
   ! PURPOSE
   !   Outputs field on a real-space FFT grid
   ! ARGUMENTS
   !   field      -  density/potential fields to be visualized
   !   field_unit -  writing unit
   !   ngrid      -  grid dimensions
   ! SOURCE
   !---------------------------------------------------------------
   subroutine output_field_grid(field,field_unit,group_name,ngrid)

   real(long)                    :: field(:,:)   ! (N_monomer, N_basis)
   integer                       :: field_unit
   character(*),intent(IN)       :: group_name
   integer                       :: ngrid(:)     ! (3)
   !***

   complex(long)   :: k_grid(0:ngrid(1)/2,&
                             0:ngrid(2)-1,&
                             0:ngrid(3)-1) 
   real(long)      :: r_grid(0:ngrid(1)-1,& 
                             0:ngrid(2)-1,&
                             0:ngrid(3)-1,&
                             N_monomer)

   type(fft_plan)     :: plan                  ! fft plan
   type(version_type) :: version               ! file format version
   integer            :: i_monomer,ix,iy,iz,ig
   character(25)      :: fmt

   call create_fft_plan(ngrid,plan)
   
   do i_monomer=1, N_monomer
      call basis_to_kgrid( field(i_monomer,:), k_grid )
      call ifft(plan,k_grid,r_grid(:,:,:,i_monomer))
   enddo

   ! Output file format version
   version%major = 1
   version%minor = 0
   call output_version(version, field_unit)

   ! Header
   call output_unit_cell(field_unit,'F')
   call output(trim(group_name),'group_name',o=field_unit)
   call output(N_monomer,'N_monomer',f='A',o=field_unit)
   call output(ngrid,dim,'ngrid',f='A',s='R',o=field_unit)

   ! Field on real-space FFT grid
   fmt = '('//trim(int_string(N_monomer))//'F18.9,4X'//')'
   do iz=0, ngrid(3)-1
      do iy=0, ngrid(2)-1
         do ix=0, ngrid(1)-1
            write(field_unit,trim(fmt)) r_grid(ix,iy,iz,:)
         enddo
      enddo
   enddo
   
   end subroutine output_field_grid
   !==============================================================

   subroutine output_fields(prefix,f_unit,omega,rho,group_name)
   !-----------------------------------------------------------------
   ! Writes the output summary to the file output_prefix//suffix
   !-----------------------------------------------------------------
   character(*) , intent(IN) :: prefix
   integer      , intent(IN) :: f_unit
   real(long)   , intent(IN) :: omega(:,:)
   real(long)   , intent(IN) :: rho(:,:) 
   character(60), intent(IN) :: group_name

   open(file=trim(prefix)//'omega', unit=f_unit,status='replace')
   call output_field(omega,f_unit,group_name)
   close(f_unit)

   open(file=trim(prefix)//'rho',unit=f_unit,status='replace')
   call output_field(rho,f_unit,group_name)
   close(f_unit)

   end subroutine output_fields
   !============================================================


end module field_io_mod
