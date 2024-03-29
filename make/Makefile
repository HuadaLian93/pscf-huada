include config.mk

# ============ Root Directories ================================
# REPO = Root directory for pscf source code repository
# SRC = $(REPO)/src = directory for source files
# BLD = $(REPO)/make = build directory for building with make
REPO=..
SRC=$(REPO)/src
BLD=$(REPO)/make

# ======  Forpedo Fortran preprocessor =========================
# FORPEDO = path to Forpedo preprocessor

FORPEDO=$(REPO)/tools/python/preprocess-0.6.1/preprocess.py

# ====== Main Program ==========================================
.PHONY: all clean install uninstall

all:
	make pscf

clean:
	rm -f  *.o  *.mod  *.f  pscf

pscf:	pscf.o\
	const_mod.o string_mod.o io_mod.o version_mod.o field_io_mod.o\
	unit_cell_mod.o group_mod.o space_groups_mod.o basis_mod.o\
	chemistry_mod.o scf_mod.o iterate_mod.o sweep_mod.o\
	step_mod.o kronrod_mod.o grid_mod.o chain_mod.o $(FFT_FILE).o grid_basis_mod.o\
	response_pd_mod.o spinodal_mod.o\
	response_mod.o response_step_mod.o extrapolate_mod.o
	$(F90) $(FOPENMP) $(LINK) -o pscf pscf.o \
	const_mod.o string_mod.o io_mod.o version_mod.o field_io_mod.o \
	unit_cell_mod.o group_mod.o space_groups_mod.o basis_mod.o \
	chemistry_mod.o scf_mod.o iterate_mod.o sweep_mod.o \
	step_mod.o kronrod_mod.o grid_mod.o chain_mod.o $(FFT_FILE).o grid_basis_mod.o \
	response_pd_mod.o spinodal_mod.o \
	response_mod.o response_step_mod.o extrapolate_mod.o \
	$(LIBDIRS) $(SHTOOLSLIB) $(FFTWLIB) $(LAPACKLIB) -lm

pscf.o: pscf.f const_mod.o io_mod.o version_mod.o\
	unit_cell_mod.o chemistry_mod.o field_io_mod.o\
	sweep_mod.o iterate_mod.o scf_mod.o basis_mod.o\
	spinodal_mod.o\
	response_mod.o $(FFT_FILE).o response_step_mod.o extrapolate_mod.o
	$(F90) $(FOPENMP) $(FAST) $(INCLUDES) -c pscf.f

pscf.f: $(SRC)/pscf.fp.f
	$(FORPEDO) $(DEVEL) $(SRC)/pscf.fp.f > pscf.f

# ====== Install =================================================

BIN_DIR=$(INSTALL)/bin
PYTHON_DIR=$(INSTALL)/lib/python2.7/site-packages

install: pscf
	mkdir -p $(BIN_DIR)
	cp pscf $(BIN_DIR)/pscf
	cp $(REPO)/tools/bin/pscf-env $(BIN_DIR)
	cp $(REPO)/tools/bin/pscf-read-sweep $(BIN_DIR)
	mkdir -p $(PYTHON_DIR)/pscf
	cp $(REPO)/tools/python/pscf/*.py $(PYTHON_DIR)/pscf

uninstall:
	rm -rf $(BIN_DIR)/pscf*
	rm -rf $(PYTHON_DIR)/pscf/*

# ====== Modules =================================================

const_mod.o: $(SRC)/const_mod.f
	$(F90) $(FAST) -c $(SRC)/const_mod.f

# io Directory
string_mod.o: $(SRC)/io/string_mod.f
	$(F90) $(FAST) -c $(SRC)/io/string_mod.f

io_mod.o: $(SRC)/io/io_mod.f const_mod.o string_mod.o
	$(F90) $(FAST) -c $(SRC)/io/io_mod.f

version_mod.o: $(SRC)/io/version_mod.f
	$(F90) $(FAST) -c $(SRC)/io/version_mod.f

field_io_mod.o: $(SRC)/io/field_io_mod.f const_mod.o io_mod.o\
	string_mod.o unit_cell_mod.o chemistry_mod.o basis_mod.o\
	$(FFT_FILE).o grid_basis_mod.o
	$(F90) $(FAST) -c $(SRC)/io/field_io_mod.f

# grid directory
kronrod_mod.o: $(SRC)/grid/kronrod_mod.f
	$(F90) $(FAST) -c $(SRC)/grid/kronrod_mod.f

grid_mod.o: $(SRC)/grid/grid_mod.f const_mod.o\
	group_mod.o unit_cell_mod.o kronrod_mod.o 
	$(F90) $(FAST) -c $(SRC)/grid/grid_mod.f

$(FFT_FILE).o: $(SRC)/grid/$(FFT_FILE).f const_mod.o
	$(F90) $(FOPENMP) $(FAST) $(INCLUDES) $(FFTWLIB)  -c $(SRC)/grid/$(FFT_FILE).f

# crystal directory
group_mod.o: $(SRC)/crystal/group_mod.f const_mod.o version_mod.o
	$(F90) $(FAST) -c $(SRC)/crystal/group_mod.f

unit_cell_mod.o: $(SRC)/crystal/unit_cell_mod.f const_mod.o\
	io_mod.o group_mod.o
	$(F90) $(FAST) -c $(SRC)/crystal/unit_cell_mod.f

space_groups_mod.o: $(SRC)/crystal/space_groups_mod.f const_mod.o\
	group_mod.o
	$(F90) $(NOPT) -c $(SRC)/crystal/space_groups_mod.f

basis_mod.o: $(SRC)/crystal/basis_mod.f\
	const_mod.o string_mod.o io_mod.o\
	group_mod.o space_groups_mod.o unit_cell_mod.o\
	grid_mod.o
	$(F90) $(FAST) -c $(SRC)/crystal/basis_mod.f

grid_basis_mod.o: $(SRC)/crystal/grid_basis_mod.f const_mod.o\
	grid_mod.o basis_mod.o
	$(F90) $(FAST) -c $(SRC)/crystal/grid_basis_mod.f

deform_mod.o: $(SRC)/crystal/deform_mod.f\
	const_mod.o string_mod.o io_mod.o\
	group_mod.o space_groups_mod.o unit_cell_mod.o\
	grid_mod.o basis_mod.o
	$(F90) $(FAST) -c $(SRC)/crystal/deform_mod.f

# scf directory

chemistry_mod.o: $(SRC)/scf/chemistry_mod.f const_mod.o io_mod.o
	$(F90) $(FAST) -c $(SRC)/scf/chemistry_mod.f

chain_mod.o: $(SRC)/scf/chain_mod.f const_mod.o\
	chemistry_mod.o kronrod_mod.o $(FFT_FILE).o
	$(F90) $(FAST) -c $(SRC)/scf/chain_mod.f

step_mod.o: $(SRC)/scf/step_mod.f const_mod.o\
	chain_mod.o unit_cell_mod.o group_mod.o $(FFT_FILE).o
	$(F90) $(FOPENMP) $(FAST) $(SHTOOL) $(SHTOOLSLIB) $(FFTWLIB) $(LAPACKLIB) -c $(SRC)/scf/step_mod.f

scf_mod.f: $(SRC)/scf/scf_mod.fp.f
	$(FORPEDO) $(DEVEL) $(SRC)/scf/scf_mod.fp.f > scf_mod.f

scf_mod.o: scf_mod.f const_mod.o io_mod.o\
	basis_mod.o chemistry_mod.o step_mod.o\
	grid_mod.o chain_mod.o $(FFT_FILE).o grid_basis_mod.o
	$(F90) $(FAST) -c scf_mod.f

#rpa directory
rpa_mod.o: $(SRC)/rpa/rpa_mod.f\
	chemistry_mod.o const_mod.o
	$(F90) $(FAST) -c $(SRC)/rpa/rpa_mod.f

spinodal_mod.o: $(SRC)/rpa/spinodal_mod.f const_mod.o io_mod.o\
	response_pd_mod.o chemistry_mod.o
	$(F90) $(FAST) -c $(SRC)/rpa/spinodal_mod.f

# iterate directory
iterate_mod.f: $(SRC)/iterate/iterate_mod.fp.f
	$(FORPEDO) $(DEVEL) $(SRC)/iterate/iterate_mod.fp.f > iterate_mod.f

iterate_mod.o: iterate_mod.f const_mod.o\
	scf_mod.o basis_mod.o chemistry_mod.o unit_cell_mod.o\
	response_pd_mod.o
	$(F90) $(FAST) -c iterate_mod.f

response_pd_mod.o: $(SRC)/iterate/response_pd_mod.f const_mod.o io_mod.o\
	chemistry_mod.o basis_mod.o unit_cell_mod.o scf_mod.o\
	grid_mod.o $(FFT_FILE).o
	$(F90) $(FAST) -c $(SRC)/iterate/response_pd_mod.f

sweep_mod.o: $(SRC)/iterate/sweep_mod.f const_mod.o io_mod.o\
	chemistry_mod.o unit_cell_mod.o basis_mod.o
	$(F90) $(FAST) -c $(SRC)/iterate/sweep_mod.f

# response directory
response_step_mod.o: $(SRC)/response/response_step_mod.f\
	chemistry_mod.o $(FFT_FILE).o
	$(F90) $(FAST) -c $(SRC)/response/response_step_mod.f

extrapolate_mod.o: $(SRC)/response/extrapolate_mod.f\
	const_mod.o
	$(F90) $(FAST) -c $(SRC)/response/extrapolate_mod.f

response_mod.o:	$(SRC)/response/response_mod.f\
	chemistry_mod.o const_mod.o chain_mod.o\
	grid_mod.o $(FFT_FILE).o group_mod.o response_step_mod.o\
	extrapolate_mod.o field_io_mod.o spinodal_mod.o
	$(F90) $(FAST) -c $(SRC)/response/response_mod.f

# ========================================================
# tests subdirectory 

rpa_test.o: $(SRC)/tests/rpa/test.f rpa_mod.o\
	chemistry_mod.o io_mod.o string_mod.o const_mod.o
	$(F90) $(FAST) -o rpa_test.o -c $(SRC)/tests/rpa/test.f

rpa_test: rpa_test.o rpa_mod.o\
	chemistry_mod.o io_mod.o string_mod.o const_mod.o
	$(F90) $(LINK) -lm -o $(SRC)/tests/rpa/exc\
	rpa_test.o rpa_mod.o\
	chemistry_mod.o io_mod.o string_mod.o const_mod.o\
	$(LAPACKLIB)

# ========================================================
# Code to convert 2D groups to Fortran
 
new_2dgroups: $(SRC)/tests/group/2dgroups/new_2dgroups.f\
	const_mod.o io_mod.o version_mod.o string_mod.o\
	group_mod.o unit_cell_mod.o
	$(F90) $(LINK) -o $(SRC)/tests/group/2dgroups/new_2dgroups\
	$(SRC)/tests/group/2dgroups/new_2dgroups.f\
	const_mod.o io_mod.o string_mod.o version_mod.o\
	group_mod.o unit_cell_mod.o

