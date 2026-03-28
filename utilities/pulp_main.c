#include "pmsis.h"

#define FC_FREQ 250
#define CL_FREQ 175

struct pi_device cluster_dev;

void cluster_main();

static int test_entry() {
    struct pi_cluster_conf cl_conf;

    /* Set FC freq. */
    pi_freq_set(PI_FREQ_DOMAIN_FC, FC_FREQ*1000000);

    /* Init cluster configuration structure. */
    pi_cluster_conf_init(&cl_conf);
    cl_conf.id = 0;
    /* Configure & open cluster. */
    pi_open_from_conf(&cluster_dev, &cl_conf);

    /* Set cluster freq. */
    pi_freq_set(PI_FREQ_DOMAIN_CL, CL_FREQ*1000000);

    /* Open cluster. */
    if (pi_cluster_open(&cluster_dev))
    {
        printf("Cluster open failed !\n");
        pmsis_exit(-1);
    }

    /* Prepare ithe cluster task and send it to cluster. */
    struct pi_cluster_task cl_task;
    pi_cluster_send_task_to_cl(&cluster_dev, pi_cluster_task(&cl_task, cluster_main, NULL));

    /* Close cluster, */
    pi_cluster_close(&cluster_dev);

    return 0;
}

static void test_kickoff(void *arg){
    int ret = test_entry();
    pmsis_exit(ret);
}

int main(){
    return pmsis_kickoff((void *)test_kickoff);
}
