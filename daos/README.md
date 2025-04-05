#### Setting up the environment

Modify the ```env_daos.sh``` file to contain the pool namd and the container name of the container you want to use and/or create. Then

On both login and compute hosts, 

	source env_daos.sh


#### Creating a container

	daos container create --type POSIX $DAOS_POOL $DAOS_CONT --properties rd_fac:1
	daos container list $DAOS_POOL
	

#### Destroying a container

	daos container destroy --force $DAOS_POOL $DAOS_CONT



#### Running an interactive job

Here is the set of commands that will mount your container on all nodes.

```
# qsub -l select=2 -l walltime=01:00:00 -A Aurora_deployment -k doe -ldaos=daos_user -l filesystems=flare:daos_user -q lustre_scaling -I
qsub -l select=2 -l walltime=30:00 -A candle_aesp_CNDA -q debug -ldaos=daos_user -l filesystems=flare:daos_user -I
```

```
# change this to your aurora_examples/daos dir is:
cd CSC249ADOA01_CNDA/brettin/aurora_examples/daos/
```

```
source env_daos.sh 

# mount_daos_compute.sh <num nodes>
mount_daos_compute.sh 2

# time mpiexec --no-vni -n <num nodes> -ppn 1 ./write_to_mount.sh
time mpiexec --no-vni -n 2 -ppn 1 ./write_to_mount.sh

# verify with
ls /tmp/$DAOS_POOL/$DAOS_CONT | wc
du -sh /tmp/$DAOS_POOL/$DAOS_CONT
```

```
# umount_daos_compute.sh <num nodes>
umount_daos_compute.sh 2
```

#### Getting results back on lustre filesystem using login host
```
# change this to your aurora_examples/daos dir is:
cd CSC249ADOA01_CNDA/brettin/aurora_examples/daos/
```
```
source env_daos.sh
mount_daos_login.sh
ls /tmp/$DAOS_POOL/$DAOS_CONT/*.log
cp /tmp/$DAOS_POOL/$DAOS_CONT/*.log $HOME/
umount_daos_login.sh 
```


