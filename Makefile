# Load CUDA Directory
CUDA_DIR = /usr/local/cuda

# 32-bit or 64-bit  
OS_TYPE = $(shell uname -m | sed -e "s/i.86/32/" -e "s/x86_64/64/" -e "s/armv7l/32/")

# Compilers
GCC ?= g++
NVC = $(CUDA_DIR)/bin/nvcc  -ccbin $(GCC)


NVCC_FLAGS   :=	
NVCC_FLAGS   += -O2 
NVCC_FLAGS   += -m${OS_TYPE}

# Directories for Header Files 
NV_INC = -I$(CUDA_DIR)/include/ -I$(CUDA_DIR)/samples/common/inc

# Directories for Libraries
ifeq ($(OS_TYPE), 64)
  NV_LIB = -L$(CUDA_DIR)/lib64
else
  NV_LIB = -L$(CUDA_DIR)/lib
endif

LIBS ?= -lcudart -lm -lgomp

#SMS ?= 30 35 50 52
SMS ?= 52 

ifeq ($(GENCODE_FLAGS),)
  $(foreach sm,$(SMS),$(eval GENCODE_FLAGS += -gencode arch=compute_$(sm),code=sm_$(sm)))
endif

#-----------------------------------------------------------------------------#
# Build Targets
#-----------------------------------------------------------------------------#
all: build 

build: parIIR 

parIIR: parIIR.cu
	$(NVC) $(NV_INC) $(NV_LIB) $(NVCC_FLAGS) $(GENCODE_FLAGS) $^ -o $@ $(LIBS)

run: build
	./parIIR

.PHONY: clean
clean:
	rm -rf parIIR 
