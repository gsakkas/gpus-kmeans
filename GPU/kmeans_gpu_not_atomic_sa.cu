#include <string.h>
#include <float.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include "gpu_util.h"
#include "kmeans_util_sa.h"
#include "cublas_v2.h"
#include <curand.h>
#include <curand_kernel.h>

/* gpu parameters */

//#define GRID_SIZE 16
//#define BLOCK_SIZE 256

#define DIMENSION 2
// #define KMEANS
#define SA
// #define MINI_BATCHES

int main(int argc, char *argv[]) {
    
    int n, k, old_k, i, j;
    int dim = 2;
    double **points;
    
    int BLOCK_SIZE = 256; //Default
    if (argc > 1) BLOCK_SIZE = atoi(argv[1]);
    if (argc == 4) k = atoi(argv[2]);
    
    //The second input argument should be the dataset filename
    FILE *in;
    if (argc == 4) {
        in = fopen(argv[3], "r");
    } else if (argc > 2) {
        in = fopen(argv[2], "r");
    } else {
        in = stdin;
    }
    
    //Parse file
    register short read_items = -1;
    read_items = fscanf(in, "%d %d %d\n", &n ,&old_k, &dim);
    if (read_items != 3){
        printf("Something went wrong with reading the parameters!\n");
        return EXIT_FAILURE;
    }
    points = create_2D_double_array(n, dim);
    for (i =0; i<n; i++) {
        for (j=0; j<dim; j++) {
            read_items = fscanf(in, "%lf", &points[i][j]);
            if (read_items != 1) {
                printf("Something went wrong with reading the points!\n");
            }
        }
    }
    fclose(in);
    if (argc < 4) k = old_k;
        
    printf("Input Read successfully \n");
    
    //Create CUBLAS Handles
    cublasStatus_t stat;
    cublasHandle_t handle;
    
    stat = cublasCreate(&handle);
    if (stat != CUBLAS_STATUS_SUCCESS) {
        printf ("CUBLAS initialization failed\n");
        return EXIT_FAILURE;
    }
    
    // Calculate grid and block sizes
    int grid_size = (n+BLOCK_SIZE-1)/BLOCK_SIZE;
    dim3 gpu_grid(grid_size, 1);
    dim3 gpu_block(BLOCK_SIZE, 1);
    int thread_num = grid_size * BLOCK_SIZE;
    
    printf("Grid size : %dx%d\n", gpu_grid.x, gpu_grid.y);
    printf("Block size: %dx%d\n", gpu_block.x, gpu_block.y);
    
    clock_t start = clock();
    
    double **centers;
    printf("Initializing Centers...\n");
    centers = init_centers_kpp(points, n, k, dim);
    printf("Initializing Centers done\n");
    
    // start algorithm
    double *points_clusters;

    points_clusters = (double *)calloc(n*k, sizeof(double));
    
    // GPU allocations
    double *dev_centers, *dev_points, *dev_centers_of_points;
    double *dev_points_help;
    double *dev_new_centers;
    double *dev_points_clusters;
    int *dev_points_clusters_old;
    double *dev_points_in_cluster;
    double *dev_ones;
    //RNG CUDA States
    curandState* devStates;

    dev_centers = (double *) gpu_alloc(k*dim*sizeof(double));
    dev_points = (double *) gpu_alloc(n*dim*sizeof(double));
    dev_centers_of_points = (double *) gpu_alloc(n*dim*sizeof(double));
    dev_points_in_cluster = (double *) gpu_alloc(k*sizeof(double));
    dev_points_clusters = (double *) gpu_alloc(n*k*sizeof(double));
    dev_points_clusters_old = (int *) gpu_alloc(n*sizeof(int)); //Used for SA SAKM
    dev_new_centers = (double *) gpu_alloc(k*dim*sizeof(double));
    dev_ones = (double *) gpu_alloc(n*sizeof(double));
    dev_points_help = (double *) gpu_alloc(n*sizeof(double));
    
    printf("GPU allocs done \n");
    
    call_create_dev_ones(dev_ones, n, gpu_grid, gpu_block);
    // Transpose points and centers for cublas
    // TODO: Transpose at cublas in gpu
    double * staging_points = (double*) calloc(n*dim, sizeof(double));
    double * staging_centers = (double*) calloc(k*dim, sizeof(double));
    transpose(points, staging_points, n, dim);
    transpose(centers, staging_centers, k, dim);

    // Copy points to GPU
    if (copy_to_gpu(staging_points, dev_points, n*dim*sizeof(double)) != 0) {
        printf("Error in copy_to_gpu points\n");
        return -1;
    }

    // Copy centers to GPU
    if (copy_to_gpu(staging_centers, dev_centers, k*dim*sizeof(double)) != 0) {
        printf("Error in copy_to_gpu centers\n");
        return -1;
    }

    //Setup Random States
    cudaMalloc(&devStates,  thread_num * sizeof(curandState));
    setup_RNG_states(devStates, gpu_grid, gpu_block);

    //Init the result_cluster arrays once 
    init_point_clusters(dev_points, dev_centers, 
                        n, k, dim, 
                        gpu_grid, gpu_block,
                        dev_points_clusters, dev_points_clusters_old, 
                        devStates);

    // FIXME: For now we pass TWO matrices for centers, one normal and 
    //        one transposed. The transposed can be omitted by doing some
    //        changes in Step 1 of K-Means.
    double *dev_temp_centers,  *dev_temp_points_clusters;
    dev_temp_centers = (double *) gpu_alloc(k*dim*sizeof(double));
    dev_temp_points_clusters = (double *) gpu_alloc(n*k*sizeof(double));

    int step = 1;
    int check = 0;
    int* dev_check = (int *) gpu_alloc(sizeof(int));
    double* dev_cost = (double *) gpu_alloc(sizeof(double));

    // printf("Loop Start \n");
    // Debug
    // for(i=0;i<k;i++){
    //     for(j=0;j<k*dim;j+=k)
    //         printf("%lf,\t", staging_centers[j + i]);
    //     printf("\n");
    // }
    srand(unsigned(time(NULL)));

    /*
            SA & K-MEANS ALGORITHM
        
    */
    //SA config
    //SA starting temperature should be set so that the probablities of making moves on the very
    //first iteration should be very close to 1.
    //Start temp of 100 seems to be working good for the tested datasets
    double start_temp = 100.0;
    double temp = start_temp;
    int eq_iterations = 5000;
    double best_cost = DBL_MAX;

#ifdef SA
    //SA loop
    printf("Starting SA on GPU \n");
    int eq_counter = 0;
    int same_cost_for_n_iters = 0;
    double curr_cost = -123;
    while(eq_counter < eq_iterations) {
        
        //printf("SA Temp: %lf \n", temp);
        //Sample solution space with SA
        double cost = kmeans_on_gpu_SA(
                    dev_points,
                    dev_centers,
                    n, k, dim,
                    dev_points_clusters,
                    dev_points_clusters_old,
                    dev_points_in_cluster,
                    dev_centers_of_points,
                    dev_new_centers,
                    dev_check,
                    gpu_grid, 
                    gpu_block, 
                    handle,
                    stat,
                    dev_ones,
                    dev_points_help, 
                    dev_temp_centers, 
                    devStates, 
                    temp);

        step += 1;
        eq_counter++;
        //Acceptance checks
        if (cost <= best_cost){
            //Accept the solution immediately        
            //Found better solution
            best_cost = cost;
            //printf("Found Better Solution: %lf Temp %lf\n", cost, temp);
            cudaMemcpy(dev_centers, dev_new_centers, sizeof(double)*k*dim, cudaMemcpyDeviceToDevice);
            //Storing global best to temp_centers
            cudaMemcpy(dev_temp_centers, dev_new_centers, sizeof(double)*k*dim, cudaMemcpyDeviceToDevice);
            cudaMemcpy(dev_temp_points_clusters, dev_points_clusters, sizeof(double)*k*n, cudaMemcpyDeviceToDevice);
        } else {
            //Accept the solution with probability
            double accept_factor = 0.5; // The larger the factor the less the probability becomes
            //Increasing the factor is equivalent with decreasing the start_temp

            double prob = exp(-accept_factor*(cost - best_cost)/start_temp);
            double uniform = rand() / (RAND_MAX + 1.);
            if (prob > uniform){
                //Accept solution as the current one
                // printf("Accepting with Prob: %lf Diff %lf\n", prob, cost - best_cost);
                cudaMemcpy(dev_centers, dev_new_centers, sizeof(double)*k*dim, cudaMemcpyDeviceToDevice);
            }
        }
        if (curr_cost == best_cost) {
            same_cost_for_n_iters ++;            
        }
        else {
            same_cost_for_n_iters = 1;
            curr_cost = best_cost;
        }
        // Just to make it stop ealrier because it doesn't change that often
        if (same_cost_for_n_iters == 200) {
            break;
        }
    }
    //Storing global best to temp_centers
    cudaMemcpy(dev_centers, dev_temp_centers, sizeof(double)*k*dim, cudaMemcpyDeviceToDevice);
    cudaMemcpy(dev_points_clusters, dev_temp_points_clusters, sizeof(double)*k*n, cudaMemcpyDeviceToDevice);
    // printf("SA Steps %d \n", step);
#endif

    /*
        DEFAULT K-MEANS ALGORITHM
    
    */
#ifdef KMEANS
    
    step = 0;
    printf("Proper KMeans Algorithm \n");
    while (!check) {
        double cost = kmeans_on_gpu(
                        dev_points,
                        dev_centers,
                        n, k, dim,
                        dev_points_clusters,
                        dev_points_in_cluster,
                        dev_centers_of_points, 
                        dev_new_centers,
                        dev_check,
                        BLOCK_SIZE,
                        handle,
                        stat,
                        dev_ones,
                        dev_points_help, 
                        dev_temp_centers);
        
        copy_from_gpu(&check, dev_check, sizeof(int));
        //printf("Step %4d Check: %d Cost: %lf \n", step, check, cost);
        step += 1;
    }
    printf("KMeans algorithm steps %d \n", step);
#endif


    //Post Processing
    // double eval = evaluate_solution(dev_points, dev_centers, dev_points_clusters, 
    //               dev_centers_of_points, dev_points_help, 
    //               n, k, dim, 
    //               gpu_grid, gpu_block, 
    //               handle, stat);

    // printf("Final Solution Value: %lf \n", eval);

    printf("Total num. of steps is %d.\n", step);

    double time_elapsed = (double)(clock() - start) / CLOCKS_PER_SEC;

    printf("Total Time Elapsed: %lf seconds\n", time_elapsed);
    
    printf("Time per step is %lf\n", time_elapsed / step);


    // We keep the map of points to clusters in order to compute the final inertia  
    copy_from_gpu(staging_centers, dev_centers, k*dim*sizeof(double));
    copy_from_gpu(points_clusters, dev_points_clusters, n*k*sizeof(double));

    
    // Compute the final inertia
    double inertia = 0;
    int curr_cluster = 0;
    // i in points
    for(i=0;i<n;i++){
        
    // Find point cluster index
    curr_cluster = -1;
        for(j=0;j<k;j++){
            if(points_clusters[j*n+i] == 1.0){
            curr_cluster = j;
        break;
        }
    }

    // Compute distance of point from specific cluster
    double curr_dist = 0;
    for(j=0;j<dim;j++){
        curr_dist += pow(staging_centers[j*k + curr_cluster] - staging_points[j*n + i], 2);  
    }
    inertia += sqrt(curr_dist);
    }
    printf("Sum of distances of samples to their closest cluster center: %lf\n", inertia);



    FILE *f;
    //Store Performance metrics
    //For now just the time elapsed, in the future maybe we'll need memory GPU memory bandwidth etc...
    f = fopen("log.out", "w");
    fprintf(f, "Time Elapsed: %lf ", time_elapsed);
    fclose(f);
    
    // print & save results
    f = fopen("centers.out", "w");
    printf("Centers:\n");
    for (i = 0; i < k; i++) {
        for (j = 0; j < dim; j++){
            printf("%lf ", staging_centers[j*k + i]);
            fprintf(f, "%lf ", staging_centers[j*k + i]);
        }
        printf("\n");
        fprintf(f, "\n");
    }
    fclose(f);
    
    //Store Mapping Data in case we need it
    
    f = fopen("point_cluster_map.out", "w");
    for (i =0;i<k;i++){
        for (j=0;j<n;j++){
            fprintf(f, "%lf ", points_clusters[i*n + j]);    
        }
        fprintf(f, "\n");
    }
    
    fclose(f);
    
    // GPU clean
    gpu_free(dev_centers);
    gpu_free(dev_new_centers);
    gpu_free(dev_temp_centers);
    gpu_free(dev_points);
    gpu_free(dev_points_clusters);
    gpu_free(dev_temp_points_clusters);
    gpu_free(dev_points_in_cluster);
    gpu_free(dev_centers_of_points);
    gpu_free(devStates);

    stat = cublasDestroy(handle);
    if (stat != CUBLAS_STATUS_SUCCESS) {
        printf ("CUBLAS destruction failed\n");
        return EXIT_FAILURE;
    }

    // clear and exit
    delete_points(points);
    delete_points(centers);
    free(points_clusters);
    return 0;
}
