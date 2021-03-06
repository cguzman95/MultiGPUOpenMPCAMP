cmake_minimum_required(VERSION 3.10)
project(MultiGPUOpenMPCAMP)

option(CSR "" OFF)
option(CSCAtomic "" OFF)
option(CSC_LOOP_ROWS "" OFF)
option(CSD "Sparse Determinant" OFF)
option(CBD "Boolean Determinant" OFF)
option(CUID "Diagonal Indexed to A" OFF)

if(CSR)
    add_definitions(-DCSR)
endif()

if(CSC_ATOMIC)
    add_definitions(-DCSC_ATOMIC)
endif()

if(CSC_LOOP_ROWS)
    add_definitions(-DCSC_LOOP_ROWS)
endif()

if(CSD)
    add_definitions(-DCSD)
endif()

if(CBD)
    add_definitions(-DCBD)
endif()

if(CUID)
    add_definitions(-DCUID)
endif()

enable_language(CUDA)

#set(CMAKE_CUDA_STANDARD 14)
set(STD_CUDA_FLAGS "-lineinfo -arch=compute_70 -code=sm_70 -dc")
#set(WIN32 ON)

set(CAMP_CUDA_SRC libsolv.cu)
set_source_files_properties(${CAMP_CUDA_SRC} PROPERTIES COMPILE_FLAGS
        ${STD_CUDA_FLAGS})
set_source_files_properties(${CAMP_CUDA_SRC} PROPERTIES LANGUAGE CUDA)
set_source_files_properties(${CAMP_CUDA_SRC} PROPERTIES CUDA_SOURCE_PROPERTY_FORMAT OBJ)

set(CAMP_LIB_SRC ${CAMP_CUDA_SRC})
add_library(camplib ${CAMP_LIB_SRC})
target_link_libraries(camplib ${CUDA_LIBRARIES})
set_target_properties(camplib PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
set_target_properties(camplib PROPERTIES CUDA_ARCHITECTURES "70")
set_target_properties(camplib PROPERTIES
        OUTPUT_NAME camp
        PREFIX lib
        VERSION ${PACKAGE_VERSION}
        SOVERSION ${PACKAGE_VERSION}
        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib
        Fortran_MODULE_DIRECTORY ${CMAKE_BINARY_DIR})

add_executable(test test.cu)
target_link_libraries(test camplib)

set_target_properties(test PROPERTIES COMPILE_FLAGS ${STD_CUDA_FLAGS})
set_target_properties(test PROPERTIES CUDA_ARCHITECTURES "70")


