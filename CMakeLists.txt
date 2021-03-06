cmake_minimum_required(VERSION 3.5)
project(adms)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_SOURCE_DIR}/cmake/Modules/" "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Modules")
set(CMAKE_VERBOSE_MAKEFILE OFF)
set(DATA_FILES_DIR "tpch_data")

# ----------------------------------
# Project name, version & build type
# -----------------------------------

ADD_DEFINITIONS(
  -std=c++14
  -march=native
  -O3
  -ftree-vectorize -ftree-slp-vectorize -funroll-all-loops -fpeel-loops -fomit-frame-pointer 
  -DDATA_FILES_DIR=${DATA_FILES_DIR}
)

add_subdirectory(cpu)

if (NOT CMAKE_BUILD_TYPE OR CMAKE_BUILD_TYPE STREQUAL "")
    set(CMAKE_BUILD_TYPE "Release" CACHE STRING "" FORCE)
endif()

message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CMAKE_CURRENT_SOURCE_DIR}/cmake)

set(LIBS
        #gtest
        #gtest_main
        pthread
        #numa
        cudart
        )

### project dependencies

find_package(Threads)

find_package(Numa REQUIRED)
include_directories(${NUMA_INCLUDE_DIR})


find_package(CUDAAPIWrappers REQUIRED)
include_directories(${CUDA_API_WRAPPERS_INCLUDE_DIRS})
# but what about the library search path?

link_libraries(${CUDA_API_WRAPPERS_LIBS} stdc++fs)

#include_directories(SYSTEM ../)
include_directories("src")
include_directories(".") # for including <cpu/whatever> from within src

### CUDA

find_package(CUDA 9.1 REQUIRED)
include(HandleCUDAComputeCapability)


find_library(CUDA_NVTX_LIBRARY
  NAMES nvToolsExt nvTools nvtoolsext nvtools nvtx NVTX
  PATHS ${CUDA_TOOLKIT_ROOT_DIR}
  PATH_SUFFIXES "lib64" "common/lib64" "common/lib" "lib"
  DOC "Location of the CUDA Toolkit Extension (NVTX) library"
  )
mark_as_advanced(CUDA_NVTX_LIBRARY)
set(CUDA_LIBRARIES ${CUDA_LIBRARIES} ${CUDA_NVTX_LIBRARY} ${CUDA_cudadevrt_LIBRARY})


# avoid implicitly synchronization with other streams
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -DGPU --default-stream per-thread)
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --expt-relaxed-constexpr)
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -g --restrict --std=c++14 -Xcompiler -D__CORRECT_ISO_CPP11_MATH_H_PROTO -D_MWAITXINTRIN_H_INCLUDED)

set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --source-in-ptx)
#set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xptxas -dlcm=cg)

# enable NVCC warnings
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xcompiler -Wall)

# the target architecture(s)  - (see https://en.wikipedia.org/wiki/CUDA#GPUs_supported)
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --generate-code arch=compute_${CUDA_TARGET_COMPUTE_CAPABILITY},code=sm_${CUDA_TARGET_COMPUTE_CAPABILITY})
#set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --generate-code arch=compute_52,code=sm_52) # e.g. GTX 970
#set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --generate-code arch=compute_60,code=sm_60) # e.g. Tesla P100
#set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --generate-code arch=compute_61,code=sm_61) # e.g. GTX 1080Ti

# don't show deprecation warnings (which are a lot with CUDA 9)
set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Wno-deprecated-declarations)

set(CUDA_NVCC_FLAGS_DEBUG -g -O0 --generate-line-info --keep -DDEBUG)
set(CUDA_NVCC_FLAGS_RELEASE -g -O3 --generate-line-info --use_fast_math --keep -DNDEBUG)

set(CUDA_PROPAGATE_HOST_FLAGS ON)
set(CUDA_SEPARABLE_COMPILATION OFF)

include_directories(/usr/local/cuda/include)


### GCC Flags
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -DGPU -DDEBUG -O0 -g")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -DGPU")

SET(SOURCE_FILES
        src/main.cu
        src/cpu.cpp
        # expl_comp_strat/common.cpp
        src/expl_comp_strat/tpch_kit.cpp
        src/expl_comp_strat/monetdb.cpp
        cpu/vectorized.cpp
        cpu/common.cpp
        )

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "bin")
cuda_add_executable(tpch_01 ${SOURCE_FILES})
target_link_libraries(tpch_01 ${LIBS} ${NUMA_LIBRARY})

##########################
## Data table generation
##########################

add_custom_command(
    OUTPUT
        ${DATA_FILES_DIR}/1.000000/lineitem.tbl
    DEPENDS
        ${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh
    COMMAND
        +${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh 1
    COMMAND
        +mkdir -p ${DATA_FILES_DIR}/1.000000
    COMMAND
        +mv lineitem.tbl  ${DATA_FILES_DIR}/1.000000/lineitem.tbl
    COMMENT
        "Generating data table for scale factor 1"
    VERBATIM
    )
# Is this next line even necessary?
set_source_files_properties( 
	${DATA_FILES_DIR}/1.000000/lineitem.tbl PROPERTIES GENERATED true )
add_custom_target(
	data_table_sf_1 ALL
	DEPENDS 
		${DATA_FILES_DIR}/1.000000/lineitem.tbl
	)

add_custom_command(
    OUTPUT
        ${DATA_FILES_DIR}/10.000000/lineitem.tbl
    DEPENDS
        ${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh
    COMMAND
        +${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh 10
    COMMAND
        +mkdir -p ${DATA_FILES_DIR}/10.000000
    COMMAND
        +mv lineitem.tbl  ${DATA_FILES_DIR}/10.000000/lineitem.tbl
    COMMENT
        "Generating data table for scale factor 10"
    VERBATIM
    )
set_source_files_properties( 
	${DATA_FILES_DIR}/10.000000/lineitem.tbl PROPERTIES GENERATED true )
add_custom_target(
	data_table_sf_10 # Note: NOT part of ALL
	DEPENDS 
		${DATA_FILES_DIR}/10.000000/lineitem.tbl
	)

add_custom_command(
    OUTPUT
        ${DATA_FILES_DIR}/100.000000/lineitem.tbl
    DEPENDS
        ${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh
    COMMAND
        +${CMAKE_SOURCE_DIR}/scripts/genlineitem.sh 100
    COMMAND
        +mkdir -p ${DATA_FILES_DIR}/100.000000
    COMMAND
        +mv lineitem.tbl  ${DATA_FILES_DIR}/100.000000/lineitem.tbl
    COMMENT
        "Generating data table for scale factor 100"
    VERBATIM
    )
set_source_files_properties( 
	${DATA_FILES_DIR}/100.000000/lineitem.tbl PROPERTIES GENERATED true )
add_custom_target(
	data_table_sf_100 # Note: NOT part of ALL
	DEPENDS 
		${DATA_FILES_DIR}/100.000000/lineitem.tbl
	)

add_custom_target(
	notify_about_higher_sf_generation ALL
	COMMAND 
		echo "Consider generating the SF 10 and SF 100 tables by make\\'ing targets data_table_sf_10 and data_table_sf_100 respectively"
	DEPENDS
		data_table_sf_1 
		tpch_01
	)

