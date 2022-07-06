#!/bin/sh
set -e

### disable link-local ipv6 address
#network:
#  ethernets:
#    ens192:
#      dhcp4: true
#      link-local: []
#  version: 2

KUBE_VERSION=1.24.1
KUBE_RELEASE=${KUBE_VERSION%.*}
. /etc/os-release


### add repos
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list
curl -L "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${VERSION_ID}/Release.key" | sudo apt-key add -
echo "deb https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${KUBE_RELEASE}:/${KUBE_VERSION}/xUbuntu_${VERSION_ID}/ /" | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o.list
curl -L "https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/${KUBE_RELEASE}:/${KUBE_VERSION}/xUbuntu_${VERSION_ID}/Release.key" | sudo apt-key add -

curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF

### update repos
sudo apt-get update


### setup terminal
sudo apt-get install -y bash-completion binutils
echo 'colorscheme ron' >> ~/.vimrc
echo 'set tabstop=2' >> ~/.vimrc
echo 'set shiftwidth=2' >> ~/.vimrc
echo 'set expandtab' >> ~/.vimrc
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'alias c=clear' >> ~/.bashrc
echo 'complete -F __start_kubectl k' >> ~/.bashrc
sed -i '1s/^/force_color_prompt=yes\n/' ~/.bashrc


### disable linux swap and remove any existing swap partitions
sudo swapoff -a
sudo sed -i -e '/[[:space:]]\+swap[[:space:]]\+/ s/^\(.*\)$/#\1/g' /etc/fstab


### remove packages
sudo kubeadm reset -f || true
sudo crictl rm --force $(sudo crictl ps -a -q) || true
sudo apt-mark unhold kubelet kubeadm kubectl kubernetes-cni || true
sudo apt-get purge -y kubelet kubeadm kubectl kubernetes-cni || true
sudo apt-get remove -y cri-o cri-o-runc || true
sudo apt-get autoremove -y
sudo systemctl daemon-reload


### cleanup cni leftovers
sudo bash -c 'rm -rf /opt/cni/bin/* || true'
sudo bash -c 'rm -rf /etc/cni/net.d/* || true'


### install packages
sudo apt-get install -y cri-o cri-o-runc kubelet=${KUBE_VERSION}-00 kubeadm=${KUBE_VERSION}-00 kubectl=${KUBE_VERSION}-00 kubernetes-cni
sudo apt-mark hold kubelet kubeadm kubectl kubernetes-cni


### cri-o
cat <<EOF | sudo tee /etc/modules-load.d/cri-o.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-crio.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system


### kubelet should use cri-o
{
cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime remote --cgroup-driver=systemd --container-runtime-endpoint='unix:///var/run/crio/crio.sock' --runtime-request-timeout=5m"
EOF
}


### configure registries
cat <<EOF | sudo tee /etc/containers/registries.conf
[registries.search]
registries = ['docker.io']
EOF


### start services
sudo systemctl daemon-reload
sudo systemctl enable crio
sudo systemctl restart crio
sudo systemctl enable kubelet
sudo systemctl start kubelet


echo
echo "EXECUTE ON MASTER: kubeadm token create --print-join-command --ttl 0"
echo "THEN RUN THE OUTPUT AS COMMAND HERE TO ADD AS WORKER WITH SUDO"
echo
