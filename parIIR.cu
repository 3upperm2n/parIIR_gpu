// System includes
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>

// CUDA runtime
#include <cuda_runtime.h>

// helper functions and utilities to work with CUDA
#include <helper_functions.h>
#include <helper_cuda.h>
#include <helper_math.h> 

#define BIQUADS 256  // num of parallel subfilters
#define DEB 0	  // compare cpu and gpu results
#define TIMING 1  // measure the kernel execution time

__constant__ float2 NSEC[BIQUADS];
__constant__ float2 DSEC[BIQUADS];

// Parallel IIR: CPU 
void cpu_pariir(float *x, float *y, float *ns, float *dsec, float c, int len);

// Check the results from CPU and GPU 
void check(float *cpu, float *gpu, int len, int tot_chn);


__inline__ __device__
float warp_reduce_sum(float val) 
{
	val += __shfl_down(val, 16, 32);
	val += __shfl_down(val,  8, 32);
	val += __shfl_down(val,  4, 32);
	val += __shfl_down(val,  2, 32);
	val += __shfl_down(val,  1, 32);
	return val;
}

//----------------------------------------------------------------------------//
// Notes:  
//----------------------------------------------------------------------------//
__global__ void GpuParIIR (float *x, int len, float c, float *y, int warpNum)
{
	extern __shared__ float sm[];

	float *sp = &sm[BIQUADS];

	int tid = threadIdx.x;
	//int id = __mul24(blockIdx.x, blockDim.x) + threadIdx.x;

	//compute lane_id = tid % 32 
	int lane_id = tid & 0x20;

	// compute warp_id tid / 32;
	int warp_id = tid >> 5;

	int ii, jj;

	float2 u = make_float2(0.0f);
	float unew;
	float y0;

	// block size : BIQUADS
	// each thread fetch input x to shared memory
	for(ii=0; ii<len; ii+=BIQUADS)
	{
		sm[tid] = x[tid + ii];	

		__syncthreads();

		// go through each x in shared memory 
		for(jj=0; jj<BIQUADS; jj++)	
		{
			unew = sm[jj] - dot(u, DSEC[tid]);				
			u = make_float2(unew, u.x);
			y0 = dot(u, NSEC[tid]);


			y0 = warp_reduce_sum(y0);

			if(lane_id == 0) sp[warp_id] = y0;

			__syncthreads();

			float val = (tid < warpNum) ? sp[lane_id] : 0.f;

			if (warp_id == 0) val = warp_reduce_sum(val);

			if(tid == 0){
				// channel starting postion: blockId.x * len
				uint gid = __mul24(blockIdx.x , len) + ii + jj;
				y[gid] = val + sm[jj] * c;	
			}
		}

	}

}


int main(int argc, char *argv[])
{

	int devid = 0;
	cudaDeviceProp prop;
	cudaGetDeviceProperties(&prop, devid);
	printf("GPU Device: %s\n\n", prop.name);

	if(argc != 2){
		printf("Missing the length of input!\nUsage: ./parIIR Len\n");
		exit(EXIT_FAILURE);	
	}

	int i, j;

	int channels = 64;

	const int blksize = 256;

	if(blksize > BIQUADS) {
		printf("Error!The block size %d is larger than %d biquads!\n",
				blksize, BIQUADS);
		exit(EXIT_FAILURE);	
	}

	if( (blksize % 32 != 0) || (BIQUADS % 32) != 0) {
		printf("Error! Either block size (%d) and biquads (%d) should be"
				"multiples of warp size (32)\n",
				blksize, BIQUADS);
		exit(EXIT_FAILURE);	
	}

	if ((BIQUADS % blksize) != 0) {
		printf("Error! BIQUADS (%d) should be evenly divided by block size (%d)!\n",
				BIQUADS, blksize);
		exit(EXIT_FAILURE);	
	}



	int len = atoi(argv[1]); // signal length 

	size_t bytes = sizeof(float) * len;

	// input
	float *x= (float*) malloc(bytes);
	for (i=0; i<len; i++){
		x[i] = 0.1f;
	}

	// output: multi-channel from GPU
	float *gpu_y= (float*) malloc(bytes * channels);

	// cpu output:
	float *cpu_y= (float*) malloc(bytes);

	float c = 3.0;

	// coefficients
	float *nsec, *dsec;
	nsec = (float*) malloc(sizeof(float) * 2 * BIQUADS); // numerator
	dsec = (float*) malloc(sizeof(float) * 3 * BIQUADS); // denominator

	// denu
	for(i=0; i<BIQUADS; i++){
		for(j=0; j<3; j++){
			//dsec[i*3 + j] = 0.00002f;
			dsec[i*3 + j] = 0.02f;
		}
	}

	// numerator : read-only
	for(i=0; i<BIQUADS; i++){
		for(j=0; j<2; j++){
			//nsec[i*2 + j] = 0.00005f;
			nsec[i*2 + j] = 0.05f;
		}
	}

	// compute the cpu results
	cpu_pariir(x, cpu_y, nsec, dsec, c, len);

	int warpsize = 32;
	//int warpnum = BIQUADS/warpsize;
	int warpNum = blksize / warpsize;

	// vectorize the coefficients
	float2 *vns, *vds;
	vns = (float2*) malloc(sizeof(float2) * BIQUADS);
	vds = (float2*) malloc(sizeof(float2) * BIQUADS); 

	for(i=0; i<BIQUADS; i++){
		//vds[i] = make_float2(0.00002f);
		//vns[i] = make_float2(0.00005f);

		vds[i] = make_float2(0.02f);
		vns[i] = make_float2(0.05f);
	}

	// timer
	cudaEvent_t start, stop;

	// device memory
	float *d_x;
	cudaMalloc((void **)&d_x, bytes);

	float *d_y;
	cudaMalloc((void **)&d_y, bytes * channels);

	// copy data to constant memory
	cudaMemcpyToSymbol(NSEC, vns, sizeof(float2)*BIQUADS, 0,
			cudaMemcpyHostToDevice);
	cudaMemcpyToSymbol(DSEC, vds, sizeof(float2)*BIQUADS, 0, 
			cudaMemcpyHostToDevice);

	cudaMemcpy(d_x, x, bytes, cudaMemcpyHostToDevice);

#if TIMING
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	// start timer
	cudaEventRecord(start, 0);
#endif

	// kernel
	GpuParIIR <<< channels, blksize, sizeof(float) * (BIQUADS + warpNum) >>> (d_x, len, c, d_y, warpNum);

#if TIMING
	// end timer
	cudaEventRecord(stop, 0);
	cudaEventSynchronize(stop);

	float et;
	cudaEventElapsedTime(&et, start, stop);
	// printf ("GPU Kernel Runtime = %f (ms)\n", et);
	printf ("GPU Runtime / channel = %.5f (ms)\n", et / (float)channels);
#endif


	cudaMemcpy(gpu_y, d_y, bytes * channels, cudaMemcpyDeviceToHost);

	check(cpu_y, gpu_y, len, channels);

	// release
	cudaFree(d_x);
	cudaFree(d_y);

	free(x);
	free(gpu_y);
	free(cpu_y);
	free(dsec);
	free(nsec);
	free(vds);
	free(vns);

}


void cpu_pariir(float *x, float *y, float *ns, float *dsec, float c, int len)
{
	int i, j;
	float out;
	float unew;

	float *ds = (float*) malloc(sizeof(float) * BIQUADS * 2);	

	// internal state
	float *u = (float*) malloc(sizeof(float) * BIQUADS * 2);
	memset(u, 0 , sizeof(float) * BIQUADS * 2);

	for(i=0; i<BIQUADS; i++)
	{
		ds[i * 2]     = dsec[3 * i + 1];
		ds[i * 2 + 1] = dsec[3 * i + 2];
	}

	long seconds, useconds;
	double mtime;
	struct timeval cpu_start, cpu_end;
	gettimeofday(&cpu_start, NULL);

	for(i=0; i<len; i++)
	{
		out = c * x[i];

		for(j=0; j<BIQUADS; j++)
		{
			unew = x[i] - (ds[j*2] * u[j*2] + ds[j*2+1] * u[j*2+1]);
			u[j*2+1] = u[j * 2];
			u[j*2] = unew;
			out = out + (u[j*2] * ns[j*2] + u[j*2 + 1] * ns[j*2 + 1]);
		}

		y[i] = out;
	}

	gettimeofday(&cpu_end, NULL);

	seconds  = cpu_end.tv_sec  - cpu_start.tv_sec;
	useconds = cpu_end.tv_usec - cpu_start.tv_usec;
	mtime = useconds;
	mtime/=1000;
	mtime+=seconds*1000;

	printf("CPU Runtime / channel = %.5f (ms)\n", mtime);


	free(ds);
	free(u);
}


void check(float *cpu, float *gpu, int len, int tot_chn)
{
	int i;
	int chn;
	uint start;
	int success = 1;


	for(chn=0; chn<tot_chn; chn++)
	{
		start = chn * len;

		for(i=0; i<len; i++)
		{
			if(cpu[i] - gpu[i + start] > 0.0001)	
			{
				puts("Failed!");
				printf("cpu %f \t gpu %f\n", cpu[i], gpu[i + start]);
				success = 0;
				break;
			}
		}
	}

	if(success)
		puts("\nVerification Passed!");

#if DEB
	for(i=0; i<len; i++)
	{
		printf("[%d]\t cpu=%f \t gpu=%f\n", i, cpu[i], gpu[i]);	
	}
#endif
}
