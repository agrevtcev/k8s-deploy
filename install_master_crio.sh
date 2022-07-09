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
echo 'set number' >> ~/.vimrc
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
#net.ipv6.conf.all.disable_ipv6 = 1
#net.ipv6.conf.default.disable_ipv6 = 1
#net.ipv6.conf.all.addr_gen_mode = 1
#net.ipv6.conf.default.addr_gen_mode = 1
EOF
sudo sysctl --system

### cilium
cat <<EOF | sudo tee /etc/modules-load.d/cilium.conf
cls_bpf
sch_ingress
sha1-ssse3
algif_hash
xt_set
ip_set
ip_set_hash_ip
EOF
sudo modprobe cls_bpf
sudo modprobe sch_ingress
sudo modprobe sha1-ssse3
sudo modprobe algif_hash
sudo modprobe xt_set
sudo modprobe ip_set
sudo modprobe ip_set_hash_ip
# https://github.com/cilium/cilium/pull/20072/commits
# not in release yet
echo 'net.ipv4.conf.lxc*.rp_filter = 0' | sudo tee -a /etc/sysctl.d/90-systemd-cilium-override.conf && sudo sysctl --system

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

### init k8s
rm ~/.kube/config || true
sudo kubeadm init --kubernetes-version=${KUBE_VERSION} --ignore-preflight-errors=NumCPU --skip-token-print --pod-network-cidr=10.142.0.0/16 --skip-phases=addon/kube-proxy

mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/$USER/.kube/config
sudo chown $USER:$USER /home/$USER/.kube/config
sudo chmod 600 /home/$USER/.kube/config


# workaround because https://github.com/weaveworks/weave/issues/3927
# kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
#curl -L https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n') -o weave.yaml
#sed -i 's/ghcr.io\/weaveworks\/launcher/docker.io\/weaveworks/g' weave.yaml
#kubectl -f weave.yaml apply
#rm weave.yaml

#curl -L https://docs.projectcalico.org/manifests/calico.yaml -o calico.yaml
#kubectl -f calico.yaml apply
#rm calico.yaml

# helm
HELM_VERSION=v3.9.0
wget https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz
tar --strip-components 1 -xzf helm-${HELM_VERSION}-linux-amd64.tar.gz linux-amd64/helm
sudo mv helm /usr/local/bin/
sudo chown root:root /usr/local/bin/helm
rm -rf helm-${HELM_VERSION}-linux-amd64.tar.gz

# etcdctl
ETCDCTL_VERSION=v3.5.1
ETCDCTL_VERSION_FULL=etcd-${ETCDCTL_VERSION}-linux-amd64
wget https://github.com/etcd-io/etcd/releases/download/${ETCDCTL_VERSION}/${ETCDCTL_VERSION_FULL}.tar.gz
tar xzf ${ETCDCTL_VERSION_FULL}.tar.gz
sudo mv ${ETCDCTL_VERSION_FULL}/etcdctl /usr/local/bin/
sudo chown root:root /usr/local/bin/etcdctl
rm -rf ${ETCDCTL_VERSION_FULL} ${ETCDCTL_VERSION_FULL}.tar.gz

# k9s
K9S_VERSION=v0.25.18
wget https://github.com/derailed/k9s/releases/download/$K9S_VERSION/k9s_Linux_x86_64.tar.gz
tar xzf k9s_Linux_x86_64.tar.gz k9s
sudo mv k9s /usr/local/bin/
sudo chown root:root /usr/local/bin/k9s
rm k9s_Linux_x86_64.tar.gz

### deploy cilium
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.11.6 -n kube-system -f values-cilium.yaml

echo
echo "### COMMAND TO ADD A WORKER NODE ###"
kubeadm token create --print-join-command --ttl 0
