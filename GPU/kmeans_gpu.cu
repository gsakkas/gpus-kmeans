#include <float.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <math.h>
#include <cuda.h>
#include "gpu_util.h"

#define MIN(X, Y) (((X) < (Y)) ? (X) : (Y))
#define MAX(X, Y) (((X) > (Y)) ? (X) : (Y))

#ifndef EPS
#   define EPS 1.e-6
#endif

/* gpu parameters */
#define GRID_SIZE 16
#define BLOCK_SIZE 256

// #define DEBUG

#ifdef DEBUG
#define DPRINTF(fmt, args...) \
do { \
    printf("%s, line %u: " fmt "\r\n", __FUNCTION__, __LINE__ , ##args); \
    fflush(stdout); \
} while (0)
#else   
#define DPRINTF(fmt, args...)   do{}while(0)
#endif


double distance(double* ps, double* center, int dim) {
    int i;
    double sum = 0;

    for (i = 0; i < dim; i++){
        double temp = center[i] - ps[i];
        sum += temp * temp;
    }

    return sum;
}

double** create_points(int n, int dim){
    double **ps, *temp;
    int i;
    temp = (double *)calloc(n * dim, sizeof(double));
    ps = (double **)calloc(n, sizeof(double *));    
    for (i = 0 ; i < n; i++)
        ps[i] = temp + i * dim;
    if (ps == NULL || temp == NULL) {
        fprintf(stderr, "Error in allocation!\n");
        exit(-1);
    }
    return ps;
}

char** create_2D_array(int k, int n){
    char **ps, *temp;
    int i;
    temp = (char *)calloc(k * n, sizeof(char));
    ps = (char **)calloc(k, sizeof(char *));    
    for (i = 0 ; i < k; i++)
        ps[i] = temp + i * n;
    if (ps == NULL || temp == NULL) {
        fprintf(stderr, "Error in allocation!\n");
        exit(-1);
    }
    return ps;
}

void delete_points(double** ps){
    free(ps);
    ps = NULL;
}

double** init_centers_kpp(double **ps, int n, int k, int dim){
    int i;
    int curr_k = 0;
    int first_i;
    int max, max_i;
    double distances_from_centers[n];
    double **centers = create_points(k,dim);
    double temp_distances[n];

    /* Initialize with max double */
    for (int i = 0; i < n; i++) distances_from_centers[i] = DBL_MAX;

    srand(time(NULL));

    /* Choose a first point */
    first_i = rand() % n;
    DPRINTF("First random index: %d", first_i);

    memcpy(centers[curr_k], ps[first_i], dim * sizeof(double));
    DPRINTF("Point 1: (%f, %f)", ps[first_i][0], ps[first_i][1]);
    DPRINTF("Center 1: (%f, %f)", centers[curr_k][0], centers[curr_k][1]);

    while(curr_k < k-1) {
        max = -1;
        max_i = -1;
        for(i=0;i<n;i++){
            DPRINTF("New distance: %f and old min distance: %f", distance(ps[i], centers[curr_k], dim), distances_from_centers[i]);
            temp_distances[i] = MIN(distance(ps[i], centers[curr_k], dim), distances_from_centers[i]);    
            if(temp_distances[i] > max){
                max = temp_distances[i];
                max_i = i;
            }
        }
 

        memcpy(distances_from_centers, temp_distances, n * sizeof(double));
        memcpy(centers[++curr_k], ps[max_i], dim * sizeof(double));
    }   
    return centers;
}



int find_cluster(double* ps, double** centers, int n, int k, int dim) {
    int cluster = 0;
    int j;
    double dist;
    double min = distance(ps, centers[0], dim);

    for (j = 1; j < k; j++){
        dist = distance(ps, centers[j], dim);
        if (min > dist){
            min = dist;
            cluster = j;
        }
    }

    return cluster;
}

double** update_centers(double** ps, int* cls, int n, int k, int dim) {
    int i, j;
    double **new_centers;
    int *points_in_cluster;

    new_centers = create_points(k, dim);
    points_in_cluster = (int*)calloc(k, sizeof(int));
    for (i = 0; i < n; i++) {
        points_in_cluster[cls[i]]++;
        for (j = 0; j < dim; j++){
            new_centers[cls[i]][j] += ps[i][j];
        }
    }

    for (i = 0; i < k; i++) {
        if (points_in_cluster[i]) {
            for (j = 0; j < dim; j++){
                new_centers[i][j] /= points_in_cluster[i];
            }
        }
    }
    // FIXME: check if points are zero and have no points in cluster
    return new_centers;
}

int main() {
    /* read input */
    int n, k, i, j;
    int dim = 2;
    double **points;
    scanf("%d %d", &n, &k);
    points = create_points(n, dim);
    for (i = 0; i < n; i++) {
        scanf("%lf %lf", &points[i][0], &points[i][1]);
    }

    dim3 gpu_grid(GRID_SIZE, 1);
    dim3 gpu_block(BLOCK_SIZE, 1);
    // size_t shmem_size = block_size * sizeof(float);

    printf("Grid size : %dx%d\n", gpu_grid.x, gpu_grid.y);
    printf("Block size: %dx%d\n", gpu_block.x, gpu_block.y);
    // printf("Shared memory size: %ld bytes\n", shmem_size);

    /* GPU allocations */
    value_t *gpu_A = (value_t *)gpu_alloc(n*n*sizeof(*gpu_A));
    if (!gpu_A) error(0, "gpu_alloc failed: %s", gpu_get_last_errmsg());
    
    /* initialize centers */
    double **centers;
    centers = init_centers_kpp(points, n, k, dim);

    /* start algorithm */
    double check = 1;
    int *points_clusters;
    double **new_centers;
    new_centers = create_points(k, dim);
    points_clusters = (int *)calloc(n, sizeof(int));

    while (check > EPS) {
        /* assign points */
        for (i = 0; i < n; i++) {
            points_clusters[i] = find_cluster(points[i], centers, n, k, dim);
        }

        /* update means */
        check = 0;
        new_centers = update_centers(points, points_clusters, n, k, dim);

        for (j = 0; j < k; j++) {
            check += sqrt(distance(new_centers[j], centers[j], dim));
            for (i = 0; i < dim; i++) centers[j][i] = new_centers[j][i];
        }
    }

    /* print results */
    printf("Centers:\n");
    for (i = 0; i < k; i++) {
        for (j = 0; j < dim; j++)
            printf("%lf ", centers[i][j]);
        printf("\n");
    }

    /* clear and exit */
    delete_points(points);
    delete_points(centers);
    return 0;
}