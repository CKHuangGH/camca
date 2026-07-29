#!/bin/bash

manage=$(awk NR==1 cp_node_list)

git clone https://github.com/CKHuangGH/camca
rm -rf /home/chuang/.ssh/known_hosts

for j in $(cat cp_node_list)
do
    scp /home/chuang/.ssh/id_rsa root@$j:/root/.ssh
    scp -r ./camca root@$j:/root/
done

echo "wait for 30 secs"
sleep 30

i=0
for j in $(cat cp_node_list)
do
ssh -o StrictHostKeyChecking=no root@$j scp -o StrictHostKeyChecking=no /root/.kube/config root@$manage:/root/.kube/cluster$i
ssh -o StrictHostKeyChecking=no root@$j chmod 777 -R /root/camca/
i=$((i+1))
done

scp cp_node_list root@$manage:/root/camca/package/cp_node_list
scp all_node_list root@$manage:/root/camca/package/all_node_list

echo "management cluster cp is $manage"