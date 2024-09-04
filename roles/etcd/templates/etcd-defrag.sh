#!/bin/bash

source /usr/local/bin/etcd.env

# 获取当前主机的IP地址
current_ip=$(hostname -i | awk '{print $1}')

# 检查etcd是否已经安装和运行
if ! command -v etcd &> /dev/null; then
    echo "etcd is not installed or not in the PATH"
    exit 1
fi

# 检查etcdctl命令行工具是否可用
if ! command -v etcdctl &> /dev/null; then
    echo "etcdctl is not installed or not in the PATH"
    exit 1
fi

# 检查etcd集群健康状态
ETCDCTL_ENDPOINTS=https://$current_ip:2379
for health_status in $(etcdctl endpoint health --cluster | awk '{print $3}' | sed 's/://g')
do
	# 如果集群不健康，则不执行碎片整理操作
	if [ "$health_status" != "healthy" ]; then
    		echo "etcd cluster is: $health_status, not healthy. Skipping compaction."
    		exit 1
	fi
done

# 获取etcd集群中的成员列表
ETCDCTL_ENDPOINTS=https://$current_ip:2379
members=$(etcdctl member list | awk -F ',' '{print $1}')

# 找到领导者节点
leader=""
for member in $members; do
    ETCDCTL_ENDPOINTS=https://$current_ip:2379
    role=$(etcdctl endpoint status --cluster | grep $member | awk -F ',' '{print $5}' | awk '{print $NF}' | head -n 1)
    if [ "$role" == "true" ]; then
        leader=$member
        break
    fi
done

# 遍历成员列表，让所有节点都进行碎片整理
for member in $members; do
    # leader 节点最后做碎片整理
    if [ "$member" == "$leader" ]; then
        echo "$member is the leader. wait others to be compacted."
        continue
    else
        echo "$member is not the leader, compacting..."
    fi

    # 获取成员的 IP
    ETCDCTL_ENDPOINTS=https://$current_ip:2379
    member_ip=$(etcdctl endpoint status --cluster | grep $member |  awk -F ',' '{print $1}' | egrep -o '[0-9.]*' | head -n 1)

    # 获取当前版本
    ETCDCTL_ENDPOINTS=https://$member_ip:2379
    rev=$(ETCDCTL_API=3 etcdctl endpoint status --write-out="json" | egrep -o '"revision":[0-9]*' | egrep -o '[0-9].*')

    # 压缩所有旧版本
    ETCDCTL_ENDPOINTS=https://$member_ip:2379
    ETCDCTL_API=3 etcdctl compact $rev

    # 整理多余的空间
    ETCDCTL_ENDPOINTS=https://$member_ip:2379
    ETCDCTL_API=3 etcdctl --command-timeout=600s defrag

    # 检查碎片整理操作是否成功
    if [ $? -eq 0 ]; then
        echo "Compaction completed successfully on member $member"
    else
        echo "Compaction failed on member $member"
    fi
done

# 如果找到领导者节点，则在该节点上再次执行碎片整理操作
if [ -n "$leader" ]; then
    # 获取成员的 IP
    ETCDCTL_ENDPOINTS=https://$current_ip:2379
    member_ip=$(etcdctl endpoint status --cluster | grep $leader |  awk -F ',' '{print $1}' | egrep -o '[0-9.]*' | head -n 1)

   # 获取当前版本
   ETCDCTL_ENDPOINTS=https://$member_ip:2379
    rev=$(ETCDCTL_API=3 etcdctl endpoint status --write-out="json" | egrep -o '"revision":[0-9]*' | egrep -o '[0-9].*')

    # 压缩所有旧版本
    ETCDCTL_ENDPOINTS=https://$member_ip:2379
    ETCDCTL_API=3 etcdctl compact $rev

    # 整理多余的空间
    ETCDCTL_ENDPOINTS=https://$member_ip:2379
    ETCDCTL_API=3 etcdctl --command-timeout=600s defrag

    # 检查碎片整理操作是否成功
    if [ $? -eq 0 ]; then
        echo "Compaction completed successfully on leader $leader"
    else
        echo "Compaction failed on leader $leader"
    fi
else
    echo "No leader found in the etcd cluster"
    exit 1
fi
