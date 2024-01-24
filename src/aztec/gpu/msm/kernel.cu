#include "common.cuh"
#include <cooperative_groups.h>
#include <cuda.h>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thrust/reduce.h>
#include <thrust/execution_policy.h>

using namespace cooperative_groups;

namespace pippenger_common {

#define MAX_THREADS_PER_BLOCK 128

/* ----------------------------------------- Sum Reduction Kernels ---------------------------------------------- */

/**
 * Naive multiplication kernel
 */
__global__ void multiplication_kernel(g1_gpu::element *point, fr_gpu *scalar, g1_gpu::element *result_vec, size_t npoints) { 
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    // 3 * N field multiplications
    fq_gpu::mul(point[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4], 
                scalar[(subgroup + (subgroup_size * blockIdx.x))].data[tid % 4], 
                result_vec[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4]);
    fq_gpu::mul(point[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4], 
                scalar[(subgroup + (subgroup_size * blockIdx.x))].data[tid % 4], 
                result_vec[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4]);
    fq_gpu::mul(point[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4], 
                scalar[(subgroup + (subgroup_size * blockIdx.x))].data[tid % 4], 
                result_vec[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4]);
}

/**
 * Sum reduction with shared memory 
 */
__global__ void sum_reduction_kernel(g1_gpu::element *points, g1_gpu::element *result) {     
    // Global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Perform reduction in shared memory
    __shared__ g1_gpu::element partial_sum[128]; 

    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x)].x.data[tid % 4], 
                partial_sum[subgroup * 2].x.data[tid % 4]);
    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x)].y.data[tid % 4], 
                partial_sum[subgroup * 2].y.data[tid % 4]);
    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x)].z.data[tid % 4], 
                partial_sum[subgroup * 2].z.data[tid % 4]);

    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x) + 1].x.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].x.data[tid % 4]);
    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x) + 1].y.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].y.data[tid % 4]);
    fq_gpu::load(points[(subgroup * 2) + ((2 * subgroup_size) * blockIdx.x) + 1].z.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].z.data[tid % 4]);

    // Local sync barrier for load operations
    __syncthreads();

    /*
        For 2^10 (1024) points, the unrolled loop iteration is as follows:
            * First pass -- 1024 threads --> 512 points to 256 points
            * Second pass -- 512 threads --> 256 points to 128 points
            * Third pass -- 256 threads --> 128 points to 64 points
            * Fourth pass -- 128 threads --> 64 points to 32 points
            * Fifth pass -- 64 threads --> 32 points to 16 points
            * Sixth pass -- 32 threads --> 16 points to 8 points
            * Seventh pass -- 16 threads --> 8 points to 4 points
            * Eighth pass -- 8 threads --> 4 points to 2 points
            * Ninth pass -- 4 threads --> 2 points to 1 point
    */

    int t = blockDim.x;
    for (int s = 0; s < log2f(blockDim.x) - 1; s++) {
        if (threadIdx.x < t) {
            g1_gpu::add(
                // This indexing is not correct!
                partial_sum[subgroup * 2].x.data[tid % 4], 
                partial_sum[subgroup * 2].y.data[tid % 4], 
                partial_sum[subgroup * 2].z.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].x.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].y.data[tid % 4], 
                partial_sum[(subgroup * 2) + 1].z.data[tid % 4], 
                partial_sum[subgroup].x.data[tid % 4], 
                partial_sum[subgroup].y.data[tid % 4], 
                partial_sum[subgroup].z.data[tid % 4]
            );
            // put point doubing struct
        }
        __syncthreads();
        t -= t / 2;
    }

    // Global synchronization directive for entire grid
    grp.sync();

    // Load data from shared memory to global memory
    if (threadIdx.x < 4) {
        fq_gpu::load(partial_sum[subgroup].x.data[tid % 4], result[blockIdx.x].x.data[tid % 4]);
        fq_gpu::load(partial_sum[subgroup].y.data[tid % 4], result[blockIdx.x].y.data[tid % 4]);
        fq_gpu::load(partial_sum[subgroup].z.data[tid % 4], result[blockIdx.x].z.data[tid % 4]); 
    }    
}

/* ----------------------------------------- Naive Double-and-Add Kernel ---------------------------------------------- */

/**
 * Double and add implementation for multiple points and scalars using bit-decomposition with time complexity: O(k)
 */ 
__global__ void double_and_add_kernel(fr_gpu *test_scalars, g1_gpu::element *test_points, g1_gpu::element *final_result, size_t num_points) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    g1_gpu::element R;
    g1_gpu::element Q;

    if (tid < LIMBS) {
        // Initialize result as 0
        fq_gpu::load(0, final_result[0].x.data[tid % 4]); 
        fq_gpu::load(0, final_result[0].y.data[tid % 4]); 
        fq_gpu::load(0, final_result[0].z.data[tid % 4]); 
        // Loop for each bucket module
        for (unsigned z = 0; z < num_points; z++) {
            // Initialize 'R' to the identity element, Q to the curve point
            fq_gpu::load(0, R.x.data[tid % 4]); 
            fq_gpu::load(0, R.y.data[tid % 4]); 
            fq_gpu::load(0, R.z.data[tid % 4]); 

            // Load partial sums
            fq_gpu::load(test_points[z].x.data[tid % 4], Q.x.data[tid % 4]);
            fq_gpu::load(test_points[z].y.data[tid % 4], Q.y.data[tid % 4]);
            fq_gpu::load(test_points[z].z.data[tid % 4], Q.z.data[tid % 4]);

            // Sync loads
            __syncthreads();
    
            // Loop for each limb starting with the last limb
            for (int j = 3; j >= 0; j--) {
                // Loop for each bit of scalar
                for (int i = 64; i >= 0; i--) {   
                    // Performs bit-decompositon by traversing the bits of the scalar from MSB to LSB
                    // and extracting the i-th bit of scalar in limb.
                    if (((test_scalars[z].data[j] >> i) & 1) ? 1 : 0)
                        g1_gpu::add(
                            Q.x.data[tid % 4], Q.y.data[tid % 4], Q.z.data[tid % 4], 
                            R.x.data[tid % 4], R.y.data[tid % 4], R.z.data[tid % 4], 
                            R.x.data[tid % 4], R.y.data[tid % 4], R.z.data[tid % 4]
                        );
                    if (i != 0) 
                        g1_gpu::doubling(
                            R.x.data[tid % 4], R.y.data[tid % 4], R.z.data[tid % 4], 
                            R.x.data[tid % 4], R.y.data[tid % 4], R.z.data[tid % 4]
                        );
                }
            }
            g1_gpu::add(
                R.x.data[tid % 4], 
                R.y.data[tid % 4], 
                R.z.data[tid % 4],
                final_result[0].x.data[tid % 4],
                final_result[0].y.data[tid % 4],
                final_result[0].z.data[tid % 4],
                final_result[0].x.data[tid % 4], 
                final_result[0].y.data[tid % 4], 
                final_result[0].z.data[tid % 4]
            );
        }
    }
}

/* ----------------------------------------- Pippenger's "Bucket Method" MSM Kernels ---------------------------------------------- */

/**
 * Initialize buckets kernel for large MSM
 */
__global__ void initialize_buckets_kernel(g1_gpu::element *bucket) {     
    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    //g1_gpu::element elementForInit()
    //mike has notes on this issue and possible solution

    fq_gpu::load(fq_gpu::zero().data[tid], bucket[subgroup + (subgroup_size * blockIdx.x)].x.data[tid]);
    fq_gpu::load(fq_gpu::zero().data[tid], bucket[subgroup + (subgroup_size * blockIdx.x)].y.data[tid]);
    fq_gpu::load(fq_gpu::zero().data[tid], bucket[subgroup + (subgroup_size * blockIdx.x)].z.data[tid]);
}

/**
 * Scalar digit decomposition 
 */
__device__ __forceinline__ uint64_t decompose_scalar_digit(fr_gpu scalar, unsigned num, unsigned width) {    
    // Determine which 64-bit limb to access 
    const uint64_t limb_lsb_idx = (num * width) / 64;  
    const uint64_t shift_bits = (num * width) % 64;  

    // Shift limb to right to extract scalar digit
    uint64_t rv = scalar.data[limb_lsb_idx] >> shift_bits; 

    // Check if scalar digit crosses boundry of current limb
    if ((shift_bits + width > 64) && (limb_lsb_idx + 1 < 4)) {
        rv += scalar.data[limb_lsb_idx + 1] << (64 - shift_bits);
    }
    // Bit mask to extract LSB of size width
    rv &= ((1 << width) - 1);
    
    return rv;
}

/**
 * Decompose b-bit scalar into c-bit scalar, where c <= b
 */
__global__ void split_scalars_kernel
(unsigned *bucket_indices, unsigned *point_indices, fr_gpu *scalars, unsigned npoints, unsigned num_bucket_modules, unsigned c) {         
    unsigned bucket_index;
    unsigned current_index;
    fr_gpu scalar;

    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    for (int i = 0; i < num_bucket_modules; i++) {
        bucket_index = decompose_scalar_digit(scalars[tid], i, c);
        current_index = i * npoints + tid; 
        
        // Bitwise performs addition here -- packing information about bucket module and specific bucket index
        bucket_indices[current_index] = (i << c) | bucket_index; 
        point_indices[current_index] = tid;
    }
}

/**
 * Struct to wrap x, y, z coordinates for both points and the result parameters for gpu::add to allow for a binary
 * operation. Note: thrust::reduce takes in as its 'operator' parameter a model of the BinaryOperation class, which
 * can be instantiated as a struct as follows:
 */
struct binaryElementAdd : std::binary_function<point_t, point_t, point_t> {
    g1_gpu::element __device__ operator()(point_t element_a_point, point_t element_b_point) const { 
        g1_gpu::element result(element_a_point);
        g1_gpu::element element_a(element_a_point);
        g1_gpu::element element_b(element_b_point);

        g1_gpu::add(
            //no need to concern with tid things that are handled in the accumulate_buckets kernel, thrust will provide
            *element_a.x.data,
            *element_a.y.data,
            *element_a.z.data,
            *element_b.x.data,
            *element_b.y.data,
            *element_b.z.data,
            *result.x.data,
            *result.y.data,
            *result.z.data
        );

        if (fq_gpu::is_zero(*result.x.data) && 
            fq_gpu::is_zero(*result.y.data) && 
            fq_gpu::is_zero(*result.z.data)) {
                g1_gpu::doubling(
                    *element_b.x.data,
                    *element_b.y.data,
                    *element_b.z.data,
                    *result.x.data,
                    *result.y.data,
                    *result.z.data
                );
        }
        return (point_t) result;
    }
}; 

/**
 * Accumulation kernel adds up points in each bucket -- this can be swapped out for efficient sum reduction kernel (tree reduction method)
 * NB: Getting swapped out for efficient sum reduce kernel (thrust::reduce)
 */
__global__ void accumulate_buckets_kernel 
(point_t *buckets, unsigned *bucket_offsets, unsigned *bucket_sizes, unsigned *single_bucket_indices, 
unsigned *point_indices, g1_gpu::element *points, unsigned num_buckets) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Parameters for cooperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    // Stores the indices, sizes, and offsets of the buckets and points
    unsigned bucket_index = single_bucket_indices[(subgroup + (subgroup_size * blockIdx.x))];
    unsigned bucket_size = bucket_sizes[(subgroup + (subgroup_size * blockIdx.x))];
    unsigned bucket_offset = bucket_offsets[(subgroup + (subgroup_size * blockIdx.x))];

    printf("bucket size is: %d", bucket_size);

    // Sync loads
    grp.sync();

    // Return empty bucket
    if (bucket_size == 0) { 
        return;
    }

    //The following thrust::reduce call should generate CUDA code that executes our reduction problem as a
    //tree reduce. This should scale this kernel from O(n/4) to O(lgn).

    point_t zero_element;

    for(int i = 0; i < num_buckets; i++) {
        thrust::reduce(thrust::device, buckets, buckets + sizeof(buckets), zero_element, binaryElementAdd());
    }

    /// NB: Unsure how to do this next bit: what we want to do is use thrust::reduce to add up all the points in the
    /// individual buckets, and then return buckets with buckets[bucket_index] modified to be a single element returned
    /// by thrust reduce. Doesn't seem that bad, but considering that it is pretty vague where we are even pulling our
    /// elements from it seems murky. For the adventurer who plunders here: consider this, that buckets[bucket_index] and
    /// points[point_indices[bucketoffset + i]] both store the ith and ith + 1 element respectively. Then, Tal stores
    /// the result in the SAME place we pulled the first three add parameters from: buckets[bucket_index]. Therefore,
    /// indeed we want buckets[bucket_index] to store our results -- BUT -- do we really want to pull our parameters from
    /// there? I think not. I think we should pull BOTH element parameters from points[]. 

    /// NB: The above is long. The problem is simple in nature. We just need to figure out where to store the result of
    /// calling thrust::reduce, and we need to figure out what data from buckets OR from points we need to pull as our
    /// first and last iterators in the call to thrust::reduce. If we can do this, we should have a working thrust
    /// implementation of accumulate_buckets. 

    // --------- OLD CODE BELOW ----------
    //Naive for loop implementation, iterates over the buckets and adds them together. Bottleneck.
    // for (unsigned i = 0; i < bucket_size; i++) { 
    //     g1_gpu::add(
    //         buckets[bucket_index].x.data[tid % 4], 
    //         buckets[bucket_index].y.data[tid % 4], 
    //         buckets[bucket_index].z.data[tid % 4], 
    //         points[point_indices[bucket_offset + i]].x.data[tid % 4], 
    //         points[point_indices[bucket_offset + i]].y.data[tid % 4], 
    //         points[point_indices[bucket_offset + i]].z.data[tid % 4], 
    //         buckets[bucket_index].x.data[tid % 4], 
    //         buckets[bucket_index].y.data[tid % 4], 
    //         buckets[bucket_index].z.data[tid % 4]
    //     );

    //     if (fq_gpu::is_zero(buckets[bucket_index].x.data[tid % 4]) && 
    //         fq_gpu::is_zero(buckets[bucket_index].y.data[tid % 4]) && 
    //         fq_gpu::is_zero(buckets[bucket_index].z.data[tid % 4])) {
    //             g1_gpu::doubling(
    //                 points[point_indices[bucket_offset + i]].x.data[tid % 4], 
    //                 points[point_indices[bucket_offset + i]].y.data[tid % 4], 
    //                 points[point_indices[bucket_offset + i]].z.data[tid % 4], 
    //                 buckets[bucket_index].x.data[tid % 4], 
    //                 buckets[bucket_index].y.data[tid % 4], 
    //                 buckets[bucket_index].z.data[tid % 4]
    //             );
    //     }
    // }
}

// NOTE: since we exchanged the four thread hardcoding for our naive iteration in the iterative thrust reduction, we may have to launch 
//       the kernel with only one thread to maintain accuracy of msm results
// __global__
// void accumulate_buckets_kernel(thrust::device_vector<g1_gpu::element> bucketsThrust, thrust::device_vector<unsigned> *bucketOffsetThrust,
//  thrust::device_vector<unsigned> *bucketSizesThrust, thrust::device_vector<unsigned> *singleBucketIndicesThrust, 
// unsigned *point_indices, thrust::device_vector<g1_gpu::element> *pointsThrust, unsigned num_buckets, size_t num_points){//new parameter for num points?
    
//     ////need device vector for points
//     //
//     ////parameters for cooperative groups
//     auto grp = fixnum::layout();
//     int subgroup = grp.meta_group_rank();
//     int subgroup_size = grp.meta_group_size();
// //
//     ////Development Note/Question:
//     ////Will we need bucket_index, bucket_size and bucket_offset variables 
//     ////because the generated cuda will calculate these based off of blockId information that is generated at compile time
//     ////or do we need to still hand write these values for use?
//     //unsigned bucket_offset = bucketOffsetThrust[subgroup + subgroup_size];//not using block id multiplier; assuming thrust will do that in code generation
// //
//     ////Development Note/Question:
//     ////How to get a variable for the number of x, y, z datas in each bucket?
// //
// //
//     ////population of lists
//     if(num_buckets == 0){//returning case of empty bucket; TODO figure out bucket size unsigned variable details
//         return;
//     }

    
//     ////calculations
//     //
//     ////loop through bucket indices
//     ////loop through each bucket size
//     ////adding up each corresponding x, y, z 
//     ////before iteration termination check if any of the corresponding x, y or z data is zero -> double if so
//     for(int i = 0; i < bucketsThrust.size(); i++){
//         for(int j = 0; j < bucketSizesThrust[i]; j++){
//             for(int k = 0; k < 4; k++){
//                 //Development Note/Question:
//             //Use thrust reduce here or just make the call to the field addition Tal implemented?
//             //thrust::reduce(bucketsThrust.begin(), bucketsThrust.end()) this is hard because what should the initialization value be and 
//             //how should we define/give it a binary operation for the reduction?
//             g1_gpu::add(
//                 bucketsThrust[i].x.data[k],
//                 bucketsThrust[i].y.data[k],
//                 bucketsThrust[i].z.data[k],
//                 pointsThrust[/*pointIndicesList*/[bucket_offset + i]].x.data[k],
//                 pointsThrust[/*pointIndicesList*/[bucket_offset + i]].y.data[k],
//                 pointsThrust[/*pointIndicesList*/[bucket_offset + i]].z.data[k],
//                 bucketsThrust[i].x.data[k],
//                 bucketsThrust[i].y.data[k],
//                 bucketsThrust[i].z.data[k]
//                 );
//          //NOTE: this group add is calling function from group.cu file
//          if(fq_gpu::is_zero(bucketsThrust[i].x.data[k])
//                 && fq_gpu::is_zero(bucketsThrust[i].y.data[k])
//                 && fq_gpu::is_zero(bucketsThrust[i].z.data[k])
//             ){
//                 //doubling; TODO same reduction issue as described above
//                 g1_gpu::doubling(
//                     pointsThrust[/*pointIndicesList*/[bucket_offset + i]].x.data[k],
//                     pointsThrust[/*pointIndicesList*/[bucket_offset + i]].y.data[k],
//                     pointsThrust[/*pointIndicesList*/[bucket_offset + i]].z.data[k],
//                     bucketsThrust[i].x.data[k],
//                     bucketsThrust[i].y.data[k],
//                     bucketsThrust[i].z.data[k]
//                 );
//             }
//             }
//         }
//     }
// }


/** 
 * Running sum kernel that accumulates partial bucket sums using running sum method
 */
__global__ void bucket_running_sum_kernel(g1_gpu::element *buckets, g1_gpu::element *final_sum, uint64_t c) {     
    // Global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    g1_gpu::element line_sum;

    // Load intitial points
    fq_gpu::load(buckets[((subgroup + (subgroup_size * blockIdx.x)) + 1) * (1 << c) - 1].x.data[tid % 4], line_sum.x.data[tid % 4]);
    fq_gpu::load(buckets[((subgroup + (subgroup_size * blockIdx.x)) + 1) * (1 << c) - 1].y.data[tid % 4], line_sum.y.data[tid % 4]);
    fq_gpu::load(buckets[((subgroup + (subgroup_size * blockIdx.x)) + 1) * (1 << c) - 1].z.data[tid % 4], line_sum.z.data[tid % 4]);
    
    fq_gpu::load(line_sum.x.data[tid % 4], final_sum[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4]);
    fq_gpu::load(line_sum.y.data[tid % 4], final_sum[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4]);
    fq_gpu::load(line_sum.z.data[tid % 4], final_sum[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4]);

    // Sync loads
    __syncthreads();

    // Running sum method
    for (unsigned i = (1 << c) - 2; i > 0; i--) {
        g1_gpu::add(
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << c) + i].x.data[tid % 4], 
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << c) + i].y.data[tid % 4], 
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << c) + i].z.data[tid % 4],
            line_sum.x.data[tid % 4],
            line_sum.y.data[tid % 4],
            line_sum.z.data[tid % 4],
            line_sum.x.data[tid % 4],
            line_sum.y.data[tid % 4],
            line_sum.z.data[tid % 4]
        );

        g1_gpu::add(
            line_sum.x.data[tid % 4],
            line_sum.y.data[tid % 4],
            line_sum.z.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4],
            final_sum[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4]
        );

        if (fq_gpu::is_zero(final_sum[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4]) && 
            fq_gpu::is_zero(final_sum[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4]) && 
            fq_gpu::is_zero(final_sum[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4])) {
                g1_gpu::doubling(
                    line_sum.x.data[tid % 4],
                    line_sum.y.data[tid % 4],
                    line_sum.z.data[tid % 4],
                    final_sum[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4],
                    final_sum[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4],
                    final_sum[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4]
                );
        }
    }
}

/**
 * Running sum kernel that accumulates partial bucket sums
 * References PipeMSM (Algorithm 2) -- https://eprint.iacr.org/2022/999.pdf
 */
__global__ void bucket_running_sum_kernel_2(g1_gpu::element *buckets, g1_gpu::element *S_, g1_gpu::element *G_, unsigned M, unsigned U) {     
    // Global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    // Define variables
    g1_gpu::element G;
    g1_gpu::element S;

    // Initialize G and S with 0
    fq_gpu::load(0x0, G.x.data[tid % 4]);
    fq_gpu::load(0x0, G.y.data[tid % 4]);
    fq_gpu::load(0x0, G.z.data[tid % 4]);
    
    fq_gpu::load(0x0, S.x.data[tid % 4]);
    fq_gpu::load(0x0, S.y.data[tid % 4]);
    fq_gpu::load(0x0, S.z.data[tid % 4]);
    
     // Sync loads
    __syncthreads();
        
    // Each of the M segment sums of size U can be computed seperately
    for (unsigned u = U - 1; u < U; u--) { 
        g1_gpu::add(
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4], 
            G.x.data[tid % 4],
            G.y.data[tid % 4],
            G.z.data[tid % 4],
            G.x.data[tid % 4],
            G.y.data[tid % 4],
            G.z.data[tid % 4]
        );

        if (fq_gpu::is_zero(G.x.data[tid % 4]) && fq_gpu::is_zero(G.y.data[tid % 4]) && fq_gpu::is_zero(G.z.data[tid % 4])) {
            g1_gpu::doubling(
                S.x.data[tid % 4],
                S.y.data[tid % 4],
                S.z.data[tid % 4], 
                G.x.data[tid % 4],
                G.y.data[tid % 4],
                G.z.data[tid % 4]
            );
        }

        g1_gpu::add(
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4], 
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << (M - 1)) + u].x.data[tid % 4],
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << (M - 1)) + u].y.data[tid % 4],
            buckets[(subgroup + (subgroup_size * blockIdx.x)) * (1 << (M - 1)) + u].z.data[tid % 4],
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4]
        );
    }

    fq_gpu::load(S.x.data[tid % 4], S_[blockIdx.x].x.data[tid % 4]);
    fq_gpu::load(S.y.data[tid % 4], S_[blockIdx.x].y.data[tid % 4]);
    fq_gpu::load(S.z.data[tid % 4], S_[blockIdx.x].z.data[tid % 4]);
    
    fq_gpu::load(G.x.data[tid % 4], G_[blockIdx.x].x.data[tid % 4]);
    fq_gpu::load(G.y.data[tid % 4], G_[blockIdx.x].y.data[tid % 4]);
    fq_gpu::load(G.z.data[tid % 4], G_[blockIdx.x].z.data[tid % 4]);
}

__global__ void bucket_running_sum_kernel_3(g1_gpu::element *result, g1_gpu::element *S_, g1_gpu::element *G_, unsigned M, unsigned U) {     
    // Global thread ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    // Define variables
    g1_gpu::element S;
    g1_gpu::element S_k;

    // Initialize S_k and S with 0
    fq_gpu::load(0x0, S.x.data[tid % 4]);
    fq_gpu::load(0x0, S.y.data[tid % 4]);
    fq_gpu::load(0x0, S.z.data[tid % 4]);
    
    fq_gpu::load(0x0, S_k.x.data[tid % 4]);
    fq_gpu::load(0x0, S_k.y.data[tid % 4]);
    fq_gpu::load(0x0, S_k.z.data[tid % 4]);

    // Sync loads
    __syncthreads();

    // Add up each segement M for each window K
    for (unsigned m = 0; m < M - 1; m++) {  
        g1_gpu::add(
            S_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].x.data[tid % 4],
            S_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].y.data[tid % 4],
            S_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].z.data[tid % 4],
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4], 
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4]
        );

        g1_gpu::add(
            S_k.x.data[tid % 4],
            S_k.y.data[tid % 4],
            S_k.z.data[tid % 4], 
            S.x.data[tid % 4],
            S.y.data[tid % 4],
            S.z.data[tid % 4],
            S_k.x.data[tid % 4],
            S_k.y.data[tid % 4],
            S_k.z.data[tid % 4]
        );

        if (fq_gpu::is_zero(S_k.x.data[tid % 4]) && fq_gpu::is_zero(S_k.y.data[tid % 4]) && fq_gpu::is_zero(S_k.z.data[tid % 4])) {
            g1_gpu::doubling(
                S.x.data[tid % 4],
                S.y.data[tid % 4],
                S.z.data[tid % 4], 
                S_k.x.data[tid % 4],
                S_k.y.data[tid % 4],
                S_k.z.data[tid % 4]
            );
        }
    }

    __syncthreads();

    // 2.2
    unsigned v = log2f(U);
    for (unsigned m = 0; m < v; m++) {  
        g1_gpu::doubling(
            S_k.x.data[tid % 4],
            S_k.y.data[tid % 4],
            S_k.z.data[tid % 4], 
            S_k.x.data[tid % 4],
            S_k.y.data[tid % 4],
            S_k.z.data[tid % 4]
        );
    }

    __syncthreads();
  
    g1_gpu::element G_k;

    // Initialize G and S with 0
    fq_gpu::load(0x0, G_k.x.data[tid % 4]);
    fq_gpu::load(0x0, G_k.y.data[tid % 4]);
    fq_gpu::load(0x0, G_k.z.data[tid % 4]);

    // 2.3
    for (unsigned m = 0; m < M; m++) {  
        g1_gpu::add(
            G_k.x.data[tid % 4],
            G_k.y.data[tid % 4],
            G_k.z.data[tid % 4],
            G_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].x.data[tid % 4],
            G_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].y.data[tid % 4],
            G_[(subgroup + (subgroup_size * blockIdx.x)) * (M - 1) + m].z.data[tid % 4], 
            G_k.x.data[tid % 4],
            G_k.y.data[tid % 4],
            G_k.z.data[tid % 4]
        );
    }

    __syncthreads();

    // 2.4
    g1_gpu::add(
        S_k.x.data[tid % 4],
        S_k.y.data[tid % 4],
        S_k.z.data[tid % 4],
        G_k.x.data[tid % 4],
        G_k.y.data[tid % 4],
        G_k.z.data[tid % 4],
        G_k.x.data[tid % 4],
        G_k.y.data[tid % 4],
        G_k.z.data[tid % 4]
    );

    __syncthreads();

    // load result
    fq_gpu::load(S_k.x.data[tid % 4], result[blockIdx.x].x.data[tid % 4]);
    fq_gpu::load(S_k.y.data[tid % 4], result[blockIdx.x].y.data[tid % 4]);
    fq_gpu::load(S_k.z.data[tid % 4], result[blockIdx.x].z.data[tid % 4]);
}

/**
 * Final bucket accumulation to produce single group element
 */
__global__ void final_accumulation_kernel(g1_gpu::element *final_sum, g1_gpu::element *final_result, size_t num_bucket_modules, unsigned c) {
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    g1_gpu::element R;
    g1_gpu::element Q;

    fr_gpu exponent{ 1024, 0, 0, 0 };

    if (tid < LIMBS) {
        // Initialize result as 0
        fq_gpu::load(0, final_result[0].x.data[tid]); 
        fq_gpu::load(0, final_result[0].y.data[tid]); 
        fq_gpu::load(0, final_result[0].z.data[tid]); 
        // Loop for each bucket module
        for (unsigned z = 26; z > 0; z--) {
            // Initialize 'R' to the identity element, Q to the curve point
            fq_gpu::load(0, R.x.data[tid]); 
            fq_gpu::load(0, R.y.data[tid]); 
            fq_gpu::load(0, R.z.data[tid]); 

            // Load partial sums
            fq_gpu::load(final_result[0].x.data[tid], Q.x.data[tid]);
            fq_gpu::load(final_result[0].y.data[tid], Q.y.data[tid]);
            fq_gpu::load(final_result[0].z.data[tid], Q.z.data[tid]);

            // Sync loads
            __syncthreads();

            // Loop for each limb starting with the last limb
            for (int j = 3; j >= 0; j--) {
                // Loop for each bit of scalar
                for (int i = 64; i >= 0; i--) {   
                    // Performs bit-decompositon by traversing the bits of the scalar from MSB to LSB,
                    // extracting the i-th bit of scalar in limb.
                    if (((exponent.data[j] >> i) & 1) ? 1 : 0)
                        g1_gpu::add(
                            Q.x.data[tid], Q.y.data[tid], Q.z.data[tid], 
                            R.x.data[tid], R.y.data[tid], R.z.data[tid], 
                            R.x.data[tid], R.y.data[tid], R.z.data[tid]
                        );
                    if (i != 0) 
                        g1_gpu::doubling(
                            R.x.data[tid], R.y.data[tid], R.z.data[tid], 
                            R.x.data[tid], R.y.data[tid], R.z.data[tid]
                        );
                }
            }
            g1_gpu::add(
                R.x.data[tid], 
                R.y.data[tid], 
                R.z.data[tid],
                final_sum[z - 1].x.data[tid],
                final_sum[z - 1].y.data[tid],
                final_sum[z - 1].z.data[tid],
                final_result[0].x.data[tid], 
                final_result[0].y.data[tid], 
                final_result[0].z.data[tid]
            );

            if (fq_gpu::is_zero(final_result[0].x.data[tid]) 
                && fq_gpu::is_zero(final_result[0].y.data[tid]) 
                && fq_gpu::is_zero(final_result[0].z.data[tid])) {
                g1_gpu::doubling(
                    R.x.data[tid],
                    R.y.data[tid],
                    R.z.data[tid], 
                    final_result[0].x.data[tid],
                    final_result[0].y.data[tid],
                    final_result[0].z.data[tid]
                );
            }
        }
    }
}

/* ----------------------------------------- Helper Kernels ---------------------------------------------- */

/**
 * Convert affine to jacobian or projective coordinates 
 */
__global__ void affine_to_jacobian(g1_gpu::affine_element *a_point, g1_gpu::element *j_point, size_t npoints) {     
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

     // Parameters for coperative groups
    auto grp = fixnum::layout();
    int subgroup = grp.meta_group_rank();
    int subgroup_size = grp.meta_group_size();

    fq_gpu::load(
        a_point[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4], 
        j_point[(subgroup + (subgroup_size * blockIdx.x))].x.data[tid % 4]
    );
    fq_gpu::load(
        a_point[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4], 
        j_point[(subgroup + (subgroup_size * blockIdx.x))].y.data[tid % 4]
    );
    fq_gpu::load(field_gpu<fq_gpu>::one().data[tid % 4], j_point[(subgroup + (subgroup_size * blockIdx.x))].z.data[tid % 4]);
}

/**
 * Compare group elements kernel
 */
__global__ void comparator_kernel(g1_gpu::element *point, g1_gpu::element *point_2, uint64_t *result) {     
    fq_gpu lhs_zz;
    fq_gpu lhs_zzz;
    fq_gpu rhs_zz;
    fq_gpu rhs_zzz;
    fq_gpu lhs_x;
    fq_gpu lhs_y;
    fq_gpu rhs_x;
    fq_gpu rhs_y;

    int tid = blockIdx.x * blockDim.x + threadIdx.x;
    
    lhs_zz.data[tid] =  fq_gpu::square(point[0].z.data[tid], lhs_zz.data[tid]);
    lhs_zzz.data[tid] = fq_gpu::mul(lhs_zz.data[tid], point[0].z.data[tid], lhs_zzz.data[tid]);
    rhs_zz.data[tid] = fq_gpu::square(point_2[0].z.data[tid], rhs_zz.data[tid]);
    rhs_zzz.data[tid] = fq_gpu::mul(rhs_zz.data[tid], point_2[0].z.data[tid], rhs_zzz.data[tid]);
    lhs_x.data[tid] = fq_gpu::mul(point[0].x.data[tid], rhs_zz.data[tid], lhs_x.data[tid]);
    lhs_y.data[tid] = fq_gpu::mul(point[0].y.data[tid], rhs_zzz.data[tid], lhs_y.data[tid]);
    rhs_x.data[tid] = fq_gpu::mul(point_2[0].x.data[tid], lhs_zz.data[tid], rhs_x.data[tid]);
    rhs_y.data[tid] = fq_gpu::mul(point_2[0].y.data[tid], lhs_zzz.data[tid], rhs_y.data[tid]);
    result[tid] = ((lhs_x.data[tid] == rhs_x.data[tid]) && (lhs_y.data[tid] == rhs_y.data[tid]));
}

}