/* Copyright (C) 2022 Barcelona Supercomputing Center
 * SPDX-License-Identifier: MIT
 */


#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <cublas_v2.h>
#include <cuda.h>
#include <cuda_runtime.h>
#include <cusparse.h>
#include <assert.h>
#include <math.h>
#include <iostream>

#include "libsolv.h"
#include "cuda_structs.h"

#define CAMP_DEBUG_GPU
//#define DEBUG_BCG_COUNTER

const int N = 16;
const int blocksize = 16;

static void HandleError(cudaError_t err,
    const char* file,
    int line) {
    if (err != cudaSuccess) {
        printf("%s in %s at line %d\n", cudaGetErrorString(err),
            file, line);
        exit(EXIT_FAILURE);
    }
}
#define HANDLE_ERROR( err ) (HandleError( err, __FILE__, __LINE__ ))

int compare_doubles(double* x, double* y, int len, const char* s) {

    int flag = 1;
    double tol = 0.0001;
    double rel_error, abs_error;
    int n_fails = 0;
    for (int i = 0; i < len; i++) {
        abs_error = abs(x[i] - y[i]);
        if (x[i] == 0)
            rel_error = 0.;
        else
            rel_error = abs((x[i] - y[i]) / x[i]);
        if ((rel_error > tol && abs_error > 1.0E-30) || y[i] != y[i]) {
            //if(true){
            printf("compare_doubles %s rel_error %le abs_error %le for tol %le at [%d]: %le vs %le\n",
                s, rel_error, abs_error, tol, i, x[i], y[i]);
            flag = 0;
            n_fails++;
            if (n_fails == 4)
                return flag;
        }
    }

    return flag;

}

__global__
void hello(char* a, int* b)
{
    a[threadIdx.x] += b[threadIdx.x];
}

void hello_test() {

    char a[N] = "Hello \0\0\0\0\0\0";
    int b[N] = { 15, 10, 6, 0, -11, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    char* ad;
    int* bd;
    const int csize = N * sizeof(char);
    const int isize = N * sizeof(int);

    printf("HANDLE_ERROR %s", a);

    HANDLE_ERROR(cudaMalloc((void**)&ad, csize));
    //cudaMalloc( (void**)&ad, csize );

    cudaMalloc((void**)&bd, isize);
    cudaMemcpy(ad, a, csize, cudaMemcpyHostToDevice);
    cudaMemcpy(bd, b, isize, cudaMemcpyHostToDevice);

    dim3 dimBlock(blocksize, 1);
    dim3 dimGrid(1, 1);
    hello << <dimGrid, dimBlock >> > (ad, bd);
    cudaMemcpy(a, ad, csize, cudaMemcpyDeviceToHost);
    cudaFree(ad);
    cudaFree(bd);

    printf("%s\n", a);

}

int nextPowerOfTwo(int v) {

    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;

    return v;
}


//Based on
// https://github.com/scipy/scipy/blob/3b36a574dc657d1ca116f6e230be694f3de31afc/scipy/sparse/sparsetools/csr.h#L363
void swapCSC_CSR(int n_row, int n_col, int* Ap, int* Aj, double* Ax, int* Bp, int* Bi, double* Bx){

  int nnz=Ap[n_row];

  memset(Bp, 0, (n_row+1)*sizeof(int));

  for (int n = 0; n < nnz; n++){
    Bp[Aj[n]]++;
  }

  //cumsum the nnz per column to get Bp[]
  for(int col = 0, cumsum = 0; col < n_col; col++){
    int temp  = Bp[col];
    Bp[col] = cumsum;
    cumsum += temp;
  }
  Bp[n_col] = nnz;

  for(int row = 0; row < n_row; row++){
    for(int jj = Ap[row]; jj < Ap[row+1]; jj++){
      int col  = Aj[jj];
      int dest = Bp[col];

      Bi[dest] = row;
      Bx[dest] = Ax[jj];

      Bp[col]++;
    }
  }

  for(int col = 0, last = 0; col <= n_col; col++){
    int temp  = Bp[col];
    Bp[col] = last;
    last    = temp;
  }

}

void swapCSC_CSR_BCG(ModelDataGPU *mGPU,
                     int *Ap, int *Aj, double *Ax){

#ifdef TEST_CSCtoCSR

  //Example configuration taken from KLU Sparse pdf
  int n_row=3;
  int n_col=n_row;
  int nnz=6;
  int Ap[n_row+1]={0,3,5,6};
  int Aj[nnz]={0,1,2,1,2,2};
  double Ax[nnz]={5.,4.,3.,2.,1.,8.};
  int* Bp=(int*)malloc((n_row+1)*sizeof(int));
  int* Bi=(int*)malloc(nnz*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#elif TEST_CSRtoCSC

  //Example configuration taken from KLU Sparse pdf
  int n_row=3;
  int n_col=n_row;
  int nnz=6;
  int Ap[n_row+1]={0,1,3,6};
  int Aj[nnz]={0,0,1,0,1,2};
  double Ax[nnz]={5.,4.,2.,3.,1.,8.};
  int* Bp=(int*)malloc((n_row+1)*sizeof(int));
  int* Bi=(int*)malloc(nnz*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#else

  int n_row=mGPU->nrows;
  int n_col=mGPU->nrows;
  int nnz=mGPU->nnz;
  int* Bp=(int*)malloc((mGPU->nrows+1)*sizeof(int));
  int* Bi=(int*)malloc(mGPU->nnz*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#endif

  swapCSC_CSR(n_row,n_col,Ap,Aj,Ax,Bp,Bi,Bx);

#ifdef TEST_CSCtoCSR

  //Correct result:
  //int Cp[n_row+1]={0,1,3,6};
  //int Ci[nnz]={0,0,1,0,1,2};
  //int Cx[nnz]={5,4,2,3,1,8};

  printf("Bp:\n");
  for(int i=0;i<=n_row;i++)
    printf("%d ",Bp[i]);
  printf("\n");
  printf("Bi:\n");
  for(int i=0;i<nnz;i++)
    printf("%d ",Bi[i]);
  printf("\n");
  printf("Bx:\n");
  for(int i=0;i<nnz;i++)
      //printf("Bpi Aj[j] %d %d \n",Bpi[Aj[j]],Aj[j]);
      //0 2 1
      //1 0 2
      //2 1 0
    printf("%-le ",Bx[i]);
  printf("\n");

  exit(0);

#elif TEST_CSRtoCSC

  //Correct result:
  //int Cp[n_row+1]={0,3,5,6};
  //int Ci[nnz]={0,1,2,1,2,2};
  //int Cx[nnz]={5,4,3,2,1,8};

  printf("Bp:\n");
  for(int i=0;i<=n_row;i++)
    printf("%d ",Bp[i]);
  printf("\n");
  printf("Bi:\n");
  for(int i=0;i<nnz;i++)
    printf("%d ",Bi[i]);
  printf("\n");
  printf("Bx:\n");
  for(int i=0;i<nnz;i++)
    printf("%-le ",Bx[i]);
  printf("\n");
  exit(0);

#else

  for(int i=0;i<=n_row;i++)
    Ap[i] = Bp[i];
  for(int i=0;i<nnz;i++)
    Aj[i] = Bi[i];
  for(int i=0;i<nnz;i++)
    Ax[i] = Bx[i];

#endif

  free(Bp);
  free(Bi);
  free(Bx);

}

void swapCSR_CSD(int n_row, int n_col, int* Ap, int* Aj, double* Ax, int* Bp, int* Bi, double* Bx){

  int nnz=Ap[n_row];

  memset(Bp, 0, (n_row+1)*sizeof(int));
  int* diags=(int*)malloc((n_row*2-1)*sizeof(int));
  int* Bpi=(int*)malloc((n_row)*sizeof(int));
  int* BiBool=(int*)malloc((n_row*n_row)*sizeof(int));
  memset(BiBool, 0, (n_row*n_row)*sizeof(int));

  Bpi[0]=0;
  for(int i = 1; i < n_row; i++){
    Bpi[i]=n_row-i;
    //printf("Bpi i %d %d \n",Bpi[i],i);
  } //0 2 1

  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      Bp[Bpi[Aj[j]]]++; //Add value to n?? values for diagonal

      //AiBool[row*n_row+Aj[j]]=1;

      //printf("Bpi Aj[j] %d %d \n",Bpi[Aj[j]],Aj[j]);
      //0 2 1
      //1 0 2
      //2 1 0
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }
  //printf("n_row %d \n",n_row);

/*
  printf("Bpi:\n");
  for(int i=0;i<n_row;i++)
    printf("%d ",Bpi[i]);
  printf("\n");
  printf("Bp:\n");
  for(int i=0;i<n_row;i++)
    printf("%d ",Bp[i]);
  printf("\n");
*/

  //exit(0);

  memset(Bx, 0, (nnz)*sizeof(double));
  int* offsetBx=(int*)malloc((n_row)*sizeof(int));
  memset(offsetBx, 0, (n_row)*sizeof(int));
  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      //Bp[Bpi[Aj[j]]]++; //Add value to n?? values for diagonal

      if(Aj[j]<=row){
        int iDiag=Bpi[Aj[j]];
        int nElemTillDiag=0;
        for(int i = 0; i < iDiag; i++){
          nElemTillDiag+=Bp[i];
        }
        //printf("nElemTillDiag  offsetBx[iDiag] Aj[j] %d %d %d %d\n",nElemTillDiag, offsetBx[iDiag],iDiag,Aj[j]);
        Bx[nElemTillDiag+offsetBx[iDiag]]=Ax[j];
        offsetBx[iDiag]++;
        BiBool[nElemTillDiag+offsetBx[iDiag]]=1;
        //BiBool[nElemTillDiag+offsetBx[iDiag]]=1;
      }
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }

  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      //Bp[Bpi[Aj[j]]]++; //Add value to n?? values for diagonal

      if(Aj[j]>row){
        int iDiag=Bpi[Aj[j]];
        int nElemTillDiag=0;
        for(int i = 0; i < iDiag; i++){
          nElemTillDiag+=Bp[i];
        }
        //printf("nElemTillDiag  offsetBx[iDiag] Aj[j] %d %d %d %d\n",nElemTillDiag, offsetBx[iDiag],iDiag,Aj[j]);
        Bx[nElemTillDiag+offsetBx[iDiag]]=Ax[j];
        offsetBx[iDiag]++;
        BiBool[nElemTillDiag+offsetBx[iDiag]]=1;
      }
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }

  printf("BiBool:\n");
  for(int i=0;i<n_row*n_row;i++)
    printf("%d ",BiBool[i]);
  printf("\n");

  printf("Bx:\n");
  for(int i=0;i<nnz;i++)
    printf("%lf ",Bx[i]);
  printf("\n");


  exit(0);

 free(diags);
 free(BiBool);

}

void swapCSC_CSD_BCG(ModelDataGPU *mGPU,
                     int *Ap0, int *Aj0, double *Ax0){

#ifndef TEST_CSRtoCSD

  //Example configuration based in  KLU Sparse pdf
  const int n_row=3;
  const int n_col=n_row;
  int nnz=7;
  int Ap[]={0,2,4,7};
  int Aj[]={0,2,0,1,0,1, 2};
  double Ax[]={5., 7., 4.,2.,3.,1.,8.};
  /*
  int nnz=6;
  int Ap[n_row+1]={0,1,3,6};
  int Aj[nnz]={0,0,1,0,1,2};
  double Ax[nnz]={5.,4.,2.,3.,1.,8.};
   */
  int* Bp=(int*)malloc((n_row+1)*sizeof(int)); //N?? of values for each diagonal
  int* Bi=(int*)malloc(nnz*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#else

  int *Ap=Ap0;
  int *Aj=Aj0;
  double *Ax=Ax0;
  int n_row=mGPU->nrows;
  int n_col=mGPU->nrows;
  int nnz=mGPU->nnz;
  int* Bp=(int*)malloc((n_row+1)*sizeof(int));
  int* Bi=(int*)malloc(nnz*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#endif

  swapCSR_CSD(n_row,n_col,Ap,Aj,Ax,Bp,Bi,Bx);

#ifndef TEST_CSRtoCSD

  //Correct result:
  //int Cp[n_row+1]={0,3,5,6};
  //int Ci[nnz]={0,1,2,1,2,2};
  //int Cx[nnz]={5,4,3,2,1,8};

  printf("Bp:\n");
  for(int i=0;i<(n_row+1);i++)
    printf("%d ",Bp[i]);
  printf("\n");
  printf("Bi:\n");
  for(int i=0;i<nnz;i++)
    printf("%d ",Bi[i]);
  printf("\n");
  printf("Bx:\n");
  for(int i=0;i<nnz;i++)
    printf("%-le ",Bx[i]);
  printf("\n");
  exit(0);

#else

  for(int i=0;i<=n_row;i++)
    Ap[i] = Bp[i];
  for(int i=0;i<nnz;i++)
    Aj[i] = Bi[i];
  for(int i=0;i<nnz;i++)
    Ax[i] = Bx[i];

#endif

  free(Bp);
  free(Bi);
  free(Bx);

}


void swapCSR_CUID(int n_row, int n_col, int* Ap, int* Aj, double* Ax, int* Bp, int* Bi, double* Bx){

  int nnz=Ap[n_row];

  memset(Bp, 0, (n_row+1)*sizeof(int));
  int* Bpi=(int*)malloc((n_row)*sizeof(int));
  //int* BiBool=(int*)malloc((n_row*n_row)*sizeof(int));
  //memset(BiBool, 0, (n_row*n_row)*sizeof(int));

  Bpi[0]=0;
  for(int i = 1; i < n_row; i++){
    Bpi[i]=n_row-i;
    //printf("Bpi i %d %d \n",Bpi[i],i);
  } //0 2 1

  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      Bp[Bpi[Aj[j]]]++; //Add value to n?? values for diagonal

      //AiBool[row*n_row+Aj[j]]=1;

      //printf("Bpi Aj[j] %d %d \n",Bpi[Aj[j]],Aj[j]);
      //0 2 1
      //1 0 2
      //2 1 0
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }
  //printf("n_row %d \n",n_row);

/*
  printf("Bpi:\n");
  for(int i=0;i<n_row;i++)
    printf("%d ",Bpi[i]);
  printf("\n");
  printf("Bp:\n");
  for(int i=0;i<n_row;i++)
    printf("%d ",Bp[i]);
  printf("\n");
*/

  //exit(0);

  memset(Bx, 0, (nnz)*sizeof(double));
  int* offsetBx=(int*)malloc((n_row)*sizeof(int));
  memset(offsetBx, 0, (n_row)*sizeof(int));
  memset(Bi, -1, (n_row*n_row)*sizeof(int));
  printf("\n");
  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      if(Aj[j]<=row){
        int iDiag=Bpi[Aj[j]];
        int nElemTillDiag=0;
        for(int i = 0; i < iDiag; i++){
          nElemTillDiag+=Bp[i];
        }
        //printf("nElemTillDiag  offsetBx[iDiag] Aj[j] %d %d %d %d\n",nElemTillDiag, offsetBx[iDiag],iDiag,Aj[j]);
        Bx[nElemTillDiag+offsetBx[iDiag]]=Ax[j];
        int iBi=iDiag*n_row+Aj[j];
        Bi[iBi]=nElemTillDiag+offsetBx[iDiag];
        //printf("Bi[i] %d %d\n",Bi[iBi], iBi);
        //BiBool[nElemTillDiag+offsetBx[iDiag]]=1;
        offsetBx[iDiag]++;
      }
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }

  for(int row = 0; row < n_row; row++){
    for(int j = Ap[row]; j < Ap[row+1]; j++) {
      if(Aj[j]>row){
        int iDiag=Bpi[Aj[j]];
        int nElemTillDiag=0;
        for(int i = 0; i < iDiag; i++){
          nElemTillDiag+=Bp[i];
        }
        //printf("nElemTillDiag  offsetBx[iDiag] Aj[j] %d %d %d %d\n",nElemTillDiag, offsetBx[iDiag],iDiag,Aj[j]);
        Bx[nElemTillDiag+offsetBx[iDiag]]=Ax[j];
        int iBi=iDiag*n_row+Aj[j];
        Bi[iBi]=nElemTillDiag+offsetBx[iDiag];
        //printf("Bi[i] %d %d\n",Bi[iBi], iBi);
        //BiBool[nElemTillDiag+offsetBx[iDiag]]=1;
        offsetBx[iDiag]++;
      }
    }
    //0 2 1
    for(int i = 0; i < n_row; i++){
      Bpi[i]++;
      if(Bpi[i]==n_row){
        Bpi[i]=0;
      }
      //printf("Bpi i %d %d \n",Bpi[i],i);
    }//1 0 2
  }

#ifdef TEST_CSRtoCUID

  /*
  printf("BiBool:\n");
  for(int i=0;i<n_row*n_row;i++)
    printf("%d ",BiBool[i]);
  printf("\n");
   */

  printf("Bi:\n");
  for(int i=0;i<n_row*n_row;i++)
    printf("%d ",Bi[i]);
  printf("\n");

  printf("Bx:\n");
  for(int i=0;i<nnz;i++)
    printf("%le ",Bx[i]);
  printf("\n");

  exit(0);

  //free(BiBool);
#endif

  free(Bpi);
  free(offsetBx);

}

void swapCSR_CUID_BCG(ModelDataGPU *mGPU,
                     int *Ap0, int *Aj0, double *Ax0, int *Aj1){

#ifdef TEST_CSRtoCUID

  //Example configuration based in  KLU Sparse pdf
  int n_row=3;
  int n_col=n_row;
  int nnz=7;
  int Ap[n_row+1]={0,1,4,7};
  int Aj[nnz]={0,0,1,2,0,1, 2};
  double Ax[nnz]={5.,  4.,2., 7., 3.,1.,8.};
  /*
  int nnz=6;
  int Ap[n_row+1]={0,1,3,6};
  int Aj[nnz]={0,0,1,0,1,2};
  double Ax[nnz]={5.,4.,2.,3.,1.,8.};
   */
  int* Bp=(int*)malloc((n_row+1)*sizeof(int)); //N?? of values for each diagonal
  int* Bi=(int*)malloc(n_row*n_row*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#else

  int *Ap=Ap0;
  int *Aj=Aj0;
  double *Ax=Ax0;
  int n_row=mGPU->nrows;
  int n_col=mGPU->nrows;
  int nnz=mGPU->nnz;
  int* Bp=(int*)malloc((n_row+1)*sizeof(int));
  int* Bi=(int*)malloc(n_row*n_row*sizeof(int));
  double* Bx=(double*)malloc(nnz*sizeof(double));

#endif

  //for aqui sobre las A

  swapCSR_CUID(n_row,n_col,Ap,Aj,Ax,Bp,Bi,Bx);

  for(int i=0;i<n_row*n_row;i++)
    Aj1[i] = Bi[i];
  for(int i=0;i<nnz;i++)
    Ax[i] = Bx[i];

  free(Bi);
  free(Bp);
  free(Bx);

  printf("swapCSR_CUID_BCG end\n");

}


__device__ void cudaDevicereduce(double* g_idata, double* g_odata, volatile double* sdata, int n_shr_empty)
{
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

    __syncthreads();

    sdata[tid] = g_idata[i];

    __syncthreads();
    //first threads update empty positions
    if (tid < n_shr_empty)
        sdata[tid + blockDim.x] = 0.;
    __syncthreads();

    for (unsigned int s = (blockDim.x + n_shr_empty) / 2; s > 0; s >>= 1)
    {
        if (tid < s) {
            sdata[tid] += sdata[tid + s];
        }
        __syncthreads();
    }

    __syncthreads();
    *g_odata = sdata[0];
    __syncthreads();

}

__device__ void cudaDevicemaxD(double* g_idata, double* g_odata, volatile double* sdata, int n_shr_empty)
{
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

    __syncthreads();

    sdata[tid] = g_idata[i];

    __syncthreads();
    //first threads update empty positions
    if (tid < n_shr_empty)
        sdata[tid + blockDim.x] = sdata[tid];
    __syncthreads();

    for (unsigned int s = (blockDim.x + n_shr_empty) / 2; s > 0; s >>= 1)
    {
        if (tid < s) {
            if (sdata[tid + s] > sdata[tid]) sdata[tid] = sdata[tid + s];
        }
        __syncthreads();
    }

    __syncthreads();
    *g_odata = sdata[0];
    __syncthreads();

}

__global__
void cudaIterative(double* x, double* y, int n_shr_empty)
{
    extern __shared__ double sdata[];
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

    int it = 0;
    int maxIt = 100;
    double a = 0.0;
    while (it < maxIt) {

        y[i] = threadIdx.x;
        cudaDevicereduce(y, &a, sdata, n_shr_empty);
        if (threadIdx.x == 0) x[i] = a;
        cudaDevicemaxD(x, &a, sdata, n_shr_empty);

        it++;
    }

    __syncthreads();

    //if (i==0) printf("a %le\n",a);
    y[i] = a;
    __syncthreads();
    //printf("y[i] %le i %d\n",y[i],i);

}

void iterative_test() {

    int blocks = 100;
    int threads_block = 73;
    int n_shr_memory = nextPowerOfTwo(threads_block);
    int n_shr_empty = n_shr_memory - threads_block;
    int len = blocks * threads_block;

    double* x = (double*)malloc(len * sizeof(double));
    memset(x, 0, len * sizeof(double));
    double* y = (double*)malloc(len * sizeof(double));
    memset(y, 1, len * sizeof(double));

    double* dx, * dy;
    cudaMalloc((void**)&dx, len * sizeof(double));
    cudaMalloc((void**)&dy, len * sizeof(double));

    HANDLE_ERROR(cudaMemcpy(dx, x, len * sizeof(double), cudaMemcpyHostToDevice));
    HANDLE_ERROR(cudaMemcpy(dy, y, len * sizeof(double), cudaMemcpyHostToDevice));

    cudaIterative << <blocks, threads_block, n_shr_memory * sizeof(double) >> >
        (dx, dy, n_shr_empty);

    HANDLE_ERROR(cudaMemcpy(y, dy, len * sizeof(double), cudaMemcpyDeviceToHost));

    double cond = 0;
    for (int i = 0; i < threads_block; i++) {
        cond += i;
    }
    for (int i = 0; i < len; i++) {
        //printf("y[i] %le cond %le i %d\n", y[i],cond,i);
        if (y[i] != cond) {
            printf("ERROR: Wrong result\n");
            printf("y[i] %le cond %le i %d\n", y[i], cond, i);
            exit(0);
        }
    }

    printf(" iterative_test SUCCESS\n");
}

__device__
void dvcheck_input_gpud(double* x, int len, const char* s)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    //if(i<2)
    if (i < len)
    {
        printf("%s[%d]=%-le\n", s, i, x[i]);
    }
}

//Algorithm: Biconjugate gradient
__global__
void solveBcgCuda(
    ModelDataGPU md_object, double* dA, int* djA, int* diA, double* dx, double* dtempv //Input data
    , int nrows, int blocks, int n_shr_empty, int maxIt, int mattype
    , int n_cells, double tolmax, double* ddiag //Init variables
    , double* dr0, double* dr0h, double* dn0, double* dp0
    , double* dt, double* ds, double* dAx2, double* dy, double* dz// Auxiliary vectors
#ifdef CAMP_DEBUG_GPU
    , int* it_pointer, int last_blockN
#endif
)
{
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned int tid = threadIdx.x;
    int active_threads = nrows;

#ifndef DEBUG_BCG_COUNTER

    ModelDataGPU* md = &md_object;
    ModelDataVariable *mdvo = md_object.mdvo;
    ModelDataVariable dmdv_object = *md_object.mdv;
    ModelDataVariable* dmdv = &dmdv_object; //slowdowns by ~20%

#endif

    //if(tid==0)printf("blockDim.x %d\n",blockDim.x);


    //if(i<1){
    if (i < active_threads) {

        double alpha, rho0, omega0, beta, rho1, temp1, temp2;
        alpha = rho0 = omega0 = beta = rho1 = temp1 = temp2 = 1.0;

        /*alpha  = 1.0;
        rho0   = 1.0;
        omega0 = 1.0;*/

        //gpu_yequalsconst(dn0,0.0,nrows,blocks,threads);  //n0=0.0 //memset???
        //gpu_yequalsconst(dp0,0.0,nrows,blocks,threads);  //p0=0.0
        cudaDevicesetconst(dn0, 0.0, nrows);
        cudaDevicesetconst(dp0, 0.0, nrows);

        //Not needed
        /*
        cudaDevicesetconst(dr0h, 0.0, nrows);
        cudaDevicesetconst(dt, 0.0, nrows);
        cudaDevicesetconst(ds, 0.0, nrows);
        cudaDevicesetconst(dAx2, 0.0, nrows);
        cudaDevicesetconst(dy, 0.0, nrows);
        cudaDevicesetconst(dz, 0.0, nrows);
         */

      cudaDeviceSpmv(dr0, dx, nrows, dA, djA, diA, n_shr_empty); //y=A*x

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

        //printf("%d ddiag %-le\n",i,ddiag[i]);
    //printf("%d dr0 %-le\n",i, dr0[i]);

#endif

        //gpu_axpby(dr0,dtempv,1.0,-1.0,nrows,blocks,threads); // r0=1.0*rhs+-1.0r0 //y=ax+by
        cudaDeviceaxpby(dr0, dtempv, 1.0, -1.0, nrows);

        __syncthreads();
        //gpu_yequalsx(dr0h,dr0,nrows,blocks,threads);  //r0h=r0
        cudaDeviceyequalsx(dr0h, dr0, nrows);

#ifdef CAMP_DEBUG_GPU
        int it = 0;
#endif

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

        if (i == 0) {
            //printf("%d dr0[%d] %-le\n",it,i,dr0[i]);
            printf("%d %d rho1 %-le\n", it, i, rho1);
        }

        //dvcheck_input_gpud(dx,nrows,"dx");
        //dvcheck_input_gpud(dr0,nrows,"dr0");

#endif

        do
        {
            //rho1=gpu_dotxy(dr0, dr0h, aux, daux, nrows,(blocks + 1) / 2, threads);
            __syncthreads();

            cudaDevicedotxy(dr0, dr0h, &rho1, nrows, n_shr_empty);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            if (i == 0) {
                //printf("%d dr0[%d] %-le\n",it,i,dr0[i]);
                printf("%d %d rho1 rho0 %-le %-le\n", it, i, rho1, rho0);
            }
            if (isnan(rho1) || rho1 == 0.0) {
                dvcheck_input_gpud(dx, nrows, "dx");
                dvcheck_input_gpud(dr0h, nrows, "dr0h");
                dvcheck_input_gpud(dr0, nrows, "dr0");
            }

#endif

            __syncthreads();
            beta = (rho1 / rho0) * (alpha / omega0);

            __syncthreads();
            //gpu_zaxpbypc(dp0,dr0,dn0,beta,-1.0*omega0*beta,nrows,blocks,threads);   //z = ax + by + c
            cudaDevicezaxpbypc(dp0, dr0, dn0, beta, -1.0 * omega0 * beta, nrows);   //z = ax + by + c

            __syncthreads();
            //gpu_multxy(dy,ddiag,dp0,nrows,blocks,threads);  // precond y= p0*diag
            cudaDevicemultxy(dy, ddiag, dp0, nrows);

            __syncthreads();
            cudaDevicesetconst(dn0, 0.0, nrows);
            //gpu_spmv(dn0,dy,nrows,dA,djA,diA,mattype,blocks,threads);  // n0= A*y
          cudaDeviceSpmv(dn0, dy, nrows, dA, djA, diA,n_shr_empty);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            if (it == 0) {
                printf("%d %d dy dn0 ddiag %-le %-le %le\n", it, i, dy[i], dn0[i], ddiag[i]);
                //printf("%d %d dn0 %-le\n",it,i,dn0[i]);
                //printf("%d %d &temp1 %p\n",it,i,&temp1);
                //printf("%d %d &test %p\n",it,i,&test);
                //printf("%d %d &i %p\n",it,i,&i);
            }

#endif

            //temp1=gpu_dotxy(dr0h, dn0, aux, daux, nrows,(blocks + 1) / 2, threads);
            cudaDevicedotxy(dr0h, dn0, &temp1, nrows, n_shr_empty);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            if (i == 0) {
                printf("%d %d temp1 %-le\n", it, i, temp1);
                //printf("%d %d &temp1 %p\n",it,i,&temp1);
                //printf("%d %d &test %p\n",it,i,&test);
                //printf("%d %d &i %p\n",it,i,&i);
            }

#endif

            __syncthreads();
            alpha = rho1 / temp1;

            //gpu_zaxpby(1.0,dr0,-1.0*alpha,dn0,ds,nrows,blocks,threads); // a*x + b*y = z
            cudaDevicezaxpby(1.0, dr0, -1.0 * alpha, dn0, ds, nrows);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            if (i == 0) {
                printf("%d ds[%d] %-le\n", it, i, ds[i]);
            }

#endif

            __syncthreads();
            //gpu_multxy(dz,ddiag,ds,nrows,blocks,threads); // precond z=diag*s
            cudaDevicemultxy(dz, ddiag, ds, nrows); // precond z=diag*s

            //gpu_spmv(dt,dz,nrows,dA,djA,diA,mattype,blocks,threads);
            cudaDeviceSpmv(dt, dz, nrows, dA, djA, diA, n_shr_empty);

            __syncthreads();
            //gpu_multxy(dAx2,ddiag,dt,nrows,blocks,threads);
            cudaDevicemultxy(dAx2, ddiag, dt, nrows);

            __syncthreads();
            //temp1=gpu_dotxy(dz, dAx2, aux, daux, nrows,(blocks + 1) / 2, threads);
            cudaDevicedotxy(dz, dAx2, &temp1, nrows, n_shr_empty);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            //if(i>=0){
            //printf("%d ddiag[%d] %-le\n",it,i,ddiag[i]);
            //printf("%d dt[%d] %-le\n",it,i,dt[i]);
            //printf("%d dAx2[%d] %-le\n",it,i,dAx2[i]);
            //printf("%d dz[%d] %-le\n",it,i,dz[i]);
          //}

            if (i == 0) {
                printf("%d %d temp1 %-le\n", it, i, temp1);
            }

#endif

            __syncthreads();
            //temp2=gpu_dotxy(dAx2, dAx2, aux, daux, nrows,(blocks + 1) / 2, threads);
            cudaDevicedotxy(dAx2, dAx2, &temp2, nrows, n_shr_empty);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP

            if (i == 0) {
                printf("%d %d temp2 %-le\n", it, i, temp2);
            }

#endif

            __syncthreads();
            omega0 = temp1 / temp2;
            //gpu_axpy(dx,dy,alpha,nrows,blocks,threads); // x=alpha*y +x
            cudaDeviceaxpy(dx, dy, alpha, nrows); // x=alpha*y +x

            __syncthreads();
            //gpu_axpy(dx,dz,omega0,nrows,blocks,threads);
            cudaDeviceaxpy(dx, dz, omega0, nrows);

            __syncthreads();
            //gpu_zaxpby(1.0,ds,-1.0*omega0,dt,dr0,nrows,blocks,threads);
            cudaDevicezaxpby(1.0, ds, -1.0 * omega0, dt, dr0, nrows);
            cudaDevicesetconst(dt, 0.0, nrows);

            __syncthreads();
            //temp1=gpu_dotxy(dr0, dr0, aux, daux, nrows,(blocks + 1) / 2, threads);
            cudaDevicedotxy(dr0, dr0, &temp1, nrows, n_shr_empty);

            //temp1 = sqrt(temp1);
            temp1 = sqrtf(temp1);

            rho0 = rho1;
            /**/
            __syncthreads();
            /**/

            //if (tid==0) it++;
            it++;
        } while (it<maxIt && temp1>tolmax);//while(it<maxIt && temp1>tolmax);

#ifdef DEBUG_SOLVEBCGCUDA_DEEP
        if (i == 0)
            printf("%d %d %-le %-le\n", tid, it, temp1, tolmax);
#endif

        //if(it>=maxIt-1)
        //  dvcheck_input_gpud(dr0,nrows,999);
        //dvcheck_input_gpud(dr0,nrows,k++);


#ifndef DEBUG_BCG_COUNTER
        dmdv->counterBCGInternal = it; //slowdown by 50%
        *mdvo = *dmdv;
#endif


    }

}

void solveGPU_block_thr(int blocks, int threads_block, int n_shr_memory, int n_shr_empty, int offset_cells,
    ModelDataGPU* mGPU, int last_blockN, itsolver *bicg)
{

    //Init variables ("public")
    int nrows = mGPU->nrows;
    int nnz = mGPU->nnz;
    int n_cells = mGPU->n_cells;
    int maxIt = mGPU->maxIt;
    int mattype = mGPU->mattype;
    double tolmax = mGPU->tolmax;

    // Auxiliary vectors ("private")
    double* dr0 = mGPU->dr0;
    double* dr0h = mGPU->dr0h;
    double* dn0 = mGPU->dn0;
    double* dp0 = mGPU->dp0;
    double* dt = mGPU->dt;
    double* ds = mGPU->ds;
    double* dAx2 = mGPU->dAx2;
    double* dy = mGPU->dy;
    double* dz = mGPU->dz;

    int offset_nrows = (nrows / n_cells) * offset_cells;
    int offset_nnz = (nnz / n_cells) * offset_cells;
    int len_cell = nrows / n_cells;

    //Input variables
    int* djA = mGPU->djA;
    int* diA = mGPU->diA;
    double* dA = mGPU->dA + offset_nnz;
    double* ddiag = mGPU->ddiag + offset_nrows;
    double* dx = mGPU->dx + offset_nrows;
    double* dtempv = mGPU->dtempv + offset_nrows;


#ifdef DEBUG_SOLVEBCGCUDA
    printf("solveGPU_block_thr n_cells %d len_cell %d nrows %d nnz %d max_threads_block %d blocks %d threads_block %d n_shr_empty %d offset_cells %d\n",
        mGPU->n_cells, len_cell, mGPU->nrows, mGPU->nnz, n_shr_memory, blocks, threads_block, n_shr_empty, offset_cells);
#endif

    int it = 0;
    solveBcgCuda << < blocks, threads_block, n_shr_memory * sizeof(double) >> >
        //solveBcgCuda << < blocks, threads_block, threads_block * sizeof(double) >> >
        (*mGPU, dA, djA, diA, dx, dtempv, nrows, blocks, n_shr_empty, maxIt, mattype, n_cells,
            tolmax, ddiag, dr0, dr0h, dn0, dp0, dt, ds, dAx2, dy, dz
#ifdef CAMP_DEBUG_GPU
            , &it, last_blockN
#endif
            );

}

//solveGPU_block: Each block will compute only a cell/group of cells
//Algorithm: Biconjugate gradient
// dx: Input and output RHS
// dtempv: Input preconditioner RHS
void solveGPU_block(ModelDataGPU* mGPU, itsolver *bicg)
{

#ifdef DEBUG_SOLVEBCGCUDA
    if (bicg->counterBiConjGrad == 0) {
        printf("solveGPUBlock\n");
    }
#endif

    int len_cell = mGPU->nrows / mGPU->n_cells;
    int max_threads_block = nextPowerOfTwo(len_cell);
#ifdef IS_BLOCKCELLSN
    if (bicg->cells_method == BLOCKCELLSN) {
        max_threads_block = mGPU->threads;//1024;
    }
    else if (bicg->cells_method == BLOCKCELLSNHALF) {
        max_threads_block = mGPU->threads / 2;
    }
#endif

    int n_cells_block = max_threads_block / len_cell;
    int threads_block = n_cells_block * len_cell;
    int blocks = (mGPU->nrows + threads_block - 1) / threads_block;
    int n_shr_empty = max_threads_block - threads_block;

    int offset_cells = 0;
    int last_blockN = 0;

#ifdef IS_BLOCKCELLSN
    //Common kernel (Launch all blocks except the last)
    if (bicg->cells_method == BLOCKCELLSN ||
        bicg->cells_method == BLOCKCELLSNHALF
        ) {

        blocks = blocks - 1;

        if (blocks != 0) {
            solveGPU_block_thr(blocks, threads_block, max_threads_block, n_shr_empty, offset_cells,
                mGPU, last_blockN);
            last_blockN = 1;
        }
#ifdef DEBUG_SOLVEBCGCUDA
        else {
            if (bicg->counterBiConjGrad == 0) {
                printf("solveGPU_block blocks==0\n");
            }
        }
#endif

        //Update vars to launch last kernel
        offset_cells = n_cells_block * blocks;
        int n_cells_last_block = mGPU->n_cells - offset_cells;
        threads_block = n_cells_last_block * len_cell;
        max_threads_block = nextPowerOfTwo(threads_block);
        n_shr_empty = max_threads_block - threads_block;
        blocks = 1;

    }
#endif

    solveGPU_block_thr(blocks, threads_block, max_threads_block, n_shr_empty, offset_cells,
        mGPU, last_blockN,bicg);

}


void BCG() {

    //int nDevices = 1;
    //int n_cells_multiplier = 1;

  char confPath [255];
  int nDevices;
  int n_cells;
  int timesteps;

  FILE* fp;
  fp = fopen("../data/conf.txt", "r");
  if (fp == NULL)
    printf("Could not open file %s\n",confPath);
  fscanf(fp, "%s", confPath);
  fscanf(fp, "%d", &nDevices);
  fscanf(fp, "%d", &n_cells);
  //fscanf(fp, "%d", &timesteps);

  fclose(fp);

  const int cellsConfBCG = 10;
  int n_cells_multiplier = n_cells/cellsConfBCG;



  if (n_cells_multiplier==0){

  }


  ModelDataGPU* mGPUs = (ModelDataGPU*)malloc(nDevices * sizeof(ModelDataGPU));
  ModelDataGPU* mGPU = &mGPUs[0];
  ModelDataGPU mGPU0_object;
  ModelDataGPU* mGPU0 = &mGPU0_object;

  itsolver bicg_ptr;
  itsolver* bicg = &bicg_ptr;

  bicg->counterBiConjGrad = 0;
  bicg->timeBiConjGrad = 0;
  cudaEventCreate(&bicg->startBCG);
  cudaEventCreate(&bicg->stopBCG);

  fp = fopen("../data/confBCG.txt", "r");
  if (fp == NULL) {
      printf("File not found \n");
      exit(EXIT_FAILURE);
  }

  fscanf(fp, "%d", &mGPU0->n_cells);
  fscanf(fp, "%d", &mGPU0->nrows);
  fscanf(fp, "%d", &mGPU0->nnz);
  fscanf(fp, "%d", &mGPU0->maxIt);
  fscanf(fp, "%d", &mGPU0->mattype);
  fscanf(fp, "%le", &mGPU0->tolmax);

  int* jA_aux = (int*)malloc(mGPU0->nnz * sizeof(int));
  int* iA_aux = (int*)malloc((mGPU0->nrows + 1) * sizeof(int));
  double* A_aux = (double*)malloc(mGPU0->nnz * sizeof(double));
  double* diag_aux = (double*)malloc(mGPU0->nrows * sizeof(double));
  double* x_aux = (double*)malloc(mGPU0->nrows * sizeof(double));
  double* tempv_aux = (double*)malloc(mGPU0->nrows * sizeof(double));

  for (int i = 0; i < mGPU0->nnz; i++) {
      fscanf(fp, "%d", &jA_aux[i]);
      //printf("%d %d\n",i, jA_aux[i]);
  }

  for (int i = 0; i < mGPU0->nrows + 1; i++) {
      fscanf(fp, "%d", &iA_aux[i]);
      //printf("%d %d\n",i, iA[i]);
  }

  for (int i = 0; i < mGPU0->nnz; i++) {
      fscanf(fp, "%le", &A_aux[i]);
      //printf("%d %le\n",i, A[i]);
  }

  for (int i = 0; i < mGPU0->nrows; i++) {
      fscanf(fp, "%le", &diag_aux[i]);
      //printf("%d %le\n",i, diag[i]);
  }

  for (int i = 0; i < mGPU0->nrows; i++) {
      fscanf(fp, "%le", &x_aux[i]);
      //printf("%d %le\n",i, x[i]);
  }

  for (int i = 0; i < mGPU0->nrows; i++) {
      fscanf(fp, "%le", &tempv_aux[i]);
      //printf("%d %le\n",i, tempv[i]);
  }

  fclose(fp);

  /*
  for(int icell=0; icell<mGPU0->n_cells; icell++){
    printf("cell %d:\n",icell);
    for(int i=0; i<mGPU0->nrows/mGPU0->n_cells+1; i++){
      printf("%d ", iA[i+icell*(mGPU0->nrows/mGPU0->n_cells)]);
      //printf("%d %d\n",i, iA[i]);
    }
    printf("\n");
  }
*/

  int* jA = (int*)malloc(mGPU0->nnz * n_cells_multiplier * sizeof(int));
  int* iA = (int*)malloc((mGPU0->nrows * n_cells_multiplier + 1) * sizeof(int));
  double* A = (double*)malloc(mGPU0->nnz * n_cells_multiplier * sizeof(double));
  double* diag = (double*)malloc(mGPU0->nrows * n_cells_multiplier * sizeof(double));
  double* x = (double*)malloc(mGPU0->nrows * n_cells_multiplier * sizeof(double));
  double* tempv = (double*)malloc(mGPU0->nrows * n_cells_multiplier * sizeof(double));

  iA[0] = 0;
  for (int i = 0; i < n_cells_multiplier; i++) {
      //memcpy(jA+i*mGPU0->nnz, jA_aux, mGPU0->nnz*sizeof(int));
      memcpy(A + i * mGPU0->nnz, A_aux, mGPU0->nnz * sizeof(double));
      memcpy(diag + i * mGPU0->nrows, diag_aux, mGPU0->nrows * sizeof(double));
      memcpy(x + i * mGPU0->nrows, x_aux, mGPU0->nrows * sizeof(double));
      memcpy(tempv + i * mGPU0->nrows, tempv_aux, mGPU0->nrows * sizeof(double));

      for (int j = 1; j < mGPU0->nrows + 1; j++) {
          iA[j + i * mGPU0->nrows] = iA_aux[j] + i * mGPU0->nnz;// iA_aux[mGPU0->nrows] * i;
          //printf("%d ",iA[j + i * mGPU0->nrows]);
      }
      //printf("\n");

      for (int j = 0; j < mGPU0->nnz + 1; j++) {
          jA[j + i * mGPU0->nnz] = jA_aux[j] + i * mGPU0->nrows;// iA_aux[mGPU0->nrows] * i;
          //printf("%d ",iA[j + i * mGPU0->nrows]);
      }

      /*
      for(int j=0; j<mGPU0->nrows; j++) {
        printf("%le ",tempv[j + i * mGPU0->nrows]);
        printf("%le ",diag[j + i * mGPU0->nrows]);
        printf("%le ",x[j + i * mGPU0->nrows]);
      }
      printf("\n");*/

      /*
      for(int j=0; j<mGPU0->nnz; j++) {
        printf("%d ",jA[j + i * mGPU0->nnz]);
      }
      printf("\n");

      for(int j=0; j<mGPU0->nnz; j++) {
        printf("%le ",A[j + i * mGPU0->nnz]);
      }
      printf("\n");
  */
  }

  mGPU0->n_cells = mGPU0->n_cells * n_cells_multiplier;
  mGPU0->nnz = mGPU0->nnz * n_cells_multiplier;
  mGPU0->nrows = mGPU0->nrows * n_cells_multiplier;

#ifdef CSR
  printf("CSR\n");
#elif CSC_ATOMIC
  printf("CSC_ATOMIC\n");
  swapCSC_CSR_BCG(mGPU0,iA,jA,A);
#elif CSC_LOOP_ROWS
  printf("CSC_LOOP_ROWS\n");
  swapCSC_CSR_BCG(mGPU0,iA,jA,A);
#elif CSD
  printf("CSD\n");
  swapCSC_CSD_BCG(mGPU0,iA,jA,A);
#elif CUID
  printf("CUID\n");

  /*
  printf("A:\n");
  for(int i=0;i<mGPU0->nnz;i++)
  printf("%le ",A[i]);
  printf("\n");
  */

  int* jA1=(int*)malloc((mGPU0->nrows*mGPU0->nrows)*sizeof(int));
  swapCSR_CUID_BCG(mGPU0,iA,jA,A,jA1);

  /*
  printf("A:\n");
  for(int i=0;i<mGPU0->nnz;i++)
    printf("%le ",A[i]);
  printf("\n");
   */

  /*
  printf("jA:\n");
  for(int i=0;i<mGPU0->nrows *mGPU0->nrows ;i++)
    printf("%d ",jA1[i]);
  printf("\n");
*/

#else
  printf("CSR\n");
#endif

#ifdef CUID
  mGPU0->lenjA=mGPU0->nrows*mGPU0->nrows;
#else
  mGPU0->lenjA=mGPU0->nnz;
#endif

  //for(int t = 0; t < timesteps; t++){

  int offset_nnz = 0;
  int offset_nrows = 0;
  int remainder = mGPU0->n_cells % nDevices;
  for (int iDevice = 0; iDevice < nDevices; iDevice++) {
    cudaSetDevice(iDevice);
    mGPU = &mGPUs[iDevice];

    int n_cells = int(mGPU0->n_cells / nDevices);
    if (remainder != 0 && iDevice == 0) {
      //printf("REMAINDER  nDevicesMODn_cells!=0\n");
      //printf("remainder %d n_cells_total %d nDevices %d n_cells %d\n",remainder,mGPU0->n_cells,nDevices,n_cells);
      n_cells += remainder;
    }

    mGPU->n_cells = n_cells;
    mGPU->nrows = mGPU0->nrows / mGPU0->n_cells * mGPU->n_cells;
    mGPU->nnz = mGPU0->nnz / mGPU0->n_cells * mGPU->n_cells;
    mGPU->lenjA = mGPU0->lenjA / mGPU0->n_cells * mGPU->n_cells;;
    mGPU->maxIt = mGPU0->maxIt;
    mGPU->mattype = mGPU0->mattype;
    mGPU->tolmax = mGPU0->tolmax;

    mGPU->mdvCPU.counterBCGInternal = 0;
#ifndef DEBUG_BCG_COUNTER
    cudaMalloc((void**)&mGPU->mdv, sizeof(ModelDataVariable));
    cudaMalloc((void**)&mGPU->mdvo, sizeof(ModelDataVariable));
    cudaMemcpyAsync(mGPU->mdv, &mGPU->mdvCPU, sizeof(ModelDataVariable), cudaMemcpyHostToDevice, 0);
#endif

    cudaMalloc((void**)&mGPU->djA, mGPU->lenjA * sizeof(int));
    cudaMalloc((void**)&mGPU->diA, (mGPU->nrows + 1) * sizeof(int));
    cudaMalloc((void**)&mGPU->dA, mGPU->nnz * sizeof(double));
    cudaMalloc((void**)&mGPU->ddiag, mGPU->nrows * sizeof(double));
    cudaMalloc((void**)&mGPU->dx, mGPU->nrows * sizeof(double));
    cudaMalloc((void**)&mGPU->dtempv, mGPU->nrows * sizeof(double));

    //Auxiliary vectors ("private")
    double** dr0 = &mGPU->dr0;
    double** dr0h = &mGPU->dr0h;
    double** dn0 = &mGPU->dn0;
    double** dp0 = &mGPU->dp0;
    double** dt = &mGPU->dt;
    double** ds = &mGPU->ds;
    double** dAx2 = &mGPU->dAx2;
    double** dy = &mGPU->dy;
    double** dz = &mGPU->dz;
    double** daux = &mGPU->daux;

    int nrows = mGPU->nrows;
    cudaMalloc(dr0, nrows * sizeof(double));
    cudaMalloc(dr0h, nrows * sizeof(double));
    cudaMalloc(dn0, nrows * sizeof(double));
    cudaMalloc(dp0, nrows * sizeof(double));
    cudaMalloc(dt, nrows * sizeof(double));
    cudaMalloc(ds, nrows * sizeof(double));
    cudaMalloc(dAx2, nrows * sizeof(double));
    cudaMalloc(dy, nrows * sizeof(double));
    cudaMalloc(dz, nrows * sizeof(double));
    cudaMalloc(daux, nrows * sizeof(double));

    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, iDevice);
    mGPU->threads = prop.maxThreadsPerBlock;
    mGPU->blocks = (mGPU->nrows + mGPU->threads - 1) / mGPU->threads;

    offset_nnz += mGPU->nnz;
    offset_nrows += mGPU->nrows;
  }

  offset_nnz = 0;
  offset_nrows = 0;
  remainder = mGPU0->n_cells % nDevices;
  cudaSetDevice(0);
  cudaEventRecord(bicg->startBCG);
  for (int iDevice = 0; iDevice < nDevices; iDevice++) {
      cudaSetDevice(iDevice);
      mGPU = &mGPUs[iDevice];

      int n_cells = int(mGPU0->n_cells / nDevices);
      if (remainder != 0 && iDevice == 0) {
          //printf("REMAINDER  nDevicesMODn_cells!=0\n");
          //printf("remainder %d n_cells_total %d nDevices %d n_cells %d\n",remainder,mGPU0->n_cells,nDevices,n_cells);
          n_cells += remainder;
      }

      mGPU->n_cells = n_cells;
      mGPU->nrows = mGPU0->nrows / mGPU0->n_cells * mGPU->n_cells;
      mGPU->nnz = mGPU0->nnz / mGPU0->n_cells * mGPU->n_cells;
      mGPU->maxIt = mGPU0->maxIt;
      mGPU->mattype = mGPU0->mattype;
      mGPU->tolmax = mGPU0->tolmax;

      //printf("mGPU->nrows%d\n",mGPU->nrows);

#ifdef CUID
    cudaMemcpyAsync(mGPU->djA, jA1, mGPU->lenjA * sizeof(int), cudaMemcpyHostToDevice, 0);
#else
    cudaMemcpyAsync(mGPU->djA, jA, mGPU->lenjA * sizeof(int), cudaMemcpyHostToDevice, 0);
#endif
      cudaMemcpyAsync(mGPU->diA, iA, (mGPU->nrows + 1) * sizeof(int), cudaMemcpyHostToDevice, 0);
      cudaMemcpyAsync(mGPU->dA, A + offset_nnz, mGPU->nnz * sizeof(double), cudaMemcpyHostToDevice);
      cudaMemcpyAsync(mGPU->ddiag, diag + offset_nrows, mGPU->nrows * sizeof(double), cudaMemcpyHostToDevice, 0);
      cudaMemcpyAsync(mGPU->dx, x + offset_nrows, mGPU->nrows * sizeof(double), cudaMemcpyHostToDevice, 0);
      HANDLE_ERROR(cudaMemcpyAsync(mGPU->dtempv, tempv + offset_nrows, mGPU->nrows * sizeof(double), cudaMemcpyHostToDevice, 0));

      cudaDeviceSynchronize();

      solveGPU_block(mGPU,bicg);

#ifndef DEBUG_BCG_COUNTER
    cudaMemcpyAsync(&mGPU->mdvCPU, mGPU->mdvo, sizeof(ModelDataVariable), cudaMemcpyDeviceToHost);
#endif

      cudaDeviceSynchronize();
#ifdef CUID
    HANDLE_ERROR(cudaMemcpy(jA1, mGPU->djA, mGPU->lenjA * sizeof(int), cudaMemcpyDeviceToHost));
#else
    HANDLE_ERROR(cudaMemcpy(jA, mGPU->djA, mGPU->lenjA * sizeof(int), cudaMemcpyDeviceToHost));
    //HANDLE_ERROR(cudaMemcpyAsync(jA, mGPU->djA, mGPU->lenjA * sizeof(int), cudaMemcpyDeviceToHost, 0));
#endif
      cudaMemcpyAsync(iA, mGPU->diA, (mGPU->nrows + 1) * sizeof(int), cudaMemcpyDeviceToHost, 0);
      cudaMemcpyAsync(A + offset_nnz, mGPU->dA, mGPU->nnz * sizeof(double), cudaMemcpyDeviceToHost, 0);
      cudaMemcpyAsync(diag + offset_nrows, mGPU->ddiag, mGPU->nrows * sizeof(double), cudaMemcpyDeviceToHost, 0);
      cudaMemcpyAsync(x + offset_nrows, mGPU->dx, mGPU->nrows * sizeof(double), cudaMemcpyDeviceToHost, 0);
      cudaMemcpyAsync(tempv + offset_nrows, mGPU->dtempv, mGPU->nrows * sizeof(double), cudaMemcpyDeviceToHost, 0);

      offset_nnz += mGPU->nnz;
      offset_nrows += mGPU->nrows;
  }

  for (int iDevice = 1; iDevice < nDevices; iDevice++) {
    cudaSetDevice(iDevice);
    cudaDeviceSynchronize();
  }

  cudaSetDevice(0);
  cudaEventRecord(bicg->stopBCG);
  cudaEventSynchronize(bicg->stopBCG);
  float msBiConjGrad = 0.0;
  cudaEventElapsedTime(&msBiConjGrad, bicg->startBCG, bicg->stopBCG);
  bicg->timeBiConjGrad += msBiConjGrad / 1000;

#ifndef DEBUG_BCG_COUNTER
  printf("counterBCGInternal %d\n",mGPU->mdvCPU.counterBCGInternal);
#endif

    /*
      for(int icell=0; icell<mGPU0->n_cells; icell++){
        printf("cell %d:\n",icell);
        for(int i=0; i<mGPU0->nrows/mGPU0->n_cells; i++){
          printf("%le ", x[i+icell*(mGPU0->nrows/mGPU0->n_cells)]);
          //printf("%d %d\n",i, iA[i]);
        }
        printf("\n");
      }*/

  mGPU0->n_cells = mGPU0->n_cells / n_cells_multiplier;
  mGPU0->nnz = mGPU0->nnz / n_cells_multiplier;
  mGPU0->nrows = mGPU0->nrows / n_cells_multiplier;

  double* A2_aux = (double*)malloc(mGPU0->nnz * sizeof(double));
  double* x2_aux = (double*)malloc(mGPU0->nrows * sizeof(double));

  fp = fopen("../data/outBCG.txt", "r");

  for (int i = 0; i < mGPU0->nnz; i++) {
      fscanf(fp, "%le", &A2_aux[i]);
      //printf("%d %le\n",i, A[i]);
  }

  for (int i = 0; i < mGPU0->nrows; i++) {
      fscanf(fp, "%le", &x2_aux[i]);
      //printf("%d %le\n",i, x[i]);
  }

  fclose(fp);

  double* x2 = (double*)malloc(mGPU0->nrows * n_cells_multiplier * sizeof(double));

  for (int i = 0; i < n_cells_multiplier; i++) {
      memcpy(x2 + i * mGPU0->nrows, x2_aux, mGPU0->nrows * sizeof(double));

      /*
      for(int j=0; j<mGPU0->nrows; j++) {
        printf("%le ",x2[j + i * mGPU0->nrows]);
      }
      printf("\n");

      for(int j=0; j<mGPU0->nrows; j++) {
        printf("%le ",x[j + i * mGPU0->nrows]);
      }
      printf("\n");
  */

  }

  mGPU0->n_cells = mGPU0->n_cells * n_cells_multiplier;
  mGPU0->nnz = mGPU0->nnz * n_cells_multiplier;
  mGPU0->nrows = mGPU0->nrows * n_cells_multiplier;

  int flag = 1;
  if (compare_doubles(x2, x, mGPU0->nrows, "x2") == 0)  flag = 0;

  if (flag == 0)
      printf("FAIL\n");
  else
      printf("SUCCESS\n");

  printf("timeBiConjGrad %.2e\n",bicg->timeBiConjGrad);
#ifndef DEBUG_BCG_COUNTER
  printf("counterBCGInternal %d\n",mGPU->mdvCPU.counterBCGInternal);
#endif

  fp = fopen("out/timesAndCounters.csv", "w");

  fprintf(fp,"timeBiConjGrad,counterBCGInternal\n");

  fprintf(fp,"%.2e\n",bicg->timeBiConjGrad);
  printf("%d\n",mGPU->mdvCPU.counterBCGInternal);

  fclose(fp);

}

int main()
{
  //hello_test();
  BCG();

  return 0;
}
