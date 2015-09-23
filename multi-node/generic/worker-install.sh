#!/bin/bash
set -e

# List of etcd servers (http://ip:port), comma separated
export ETCD_ENDPOINTS=

# The endpoint the worker node should use to contact controller nodes (https://ip:port)
# In HA configurations this should be an external DNS record or loadbalancer in front of the control nodes.
# However, it is also possible to point directly to a single control node.
export CONTROLLER_ENDPOINT=

# Specify the version (vX.Y.Z) of Kubernetes assets to deploy
export K8S_VER=v1.0.6

# The IP address of the cluster DNS service.
# This must be the same DNS_SERVICE_IP used when configuring the controller nodes.
export DNS_SERVICE_IP=10.3.0.10

# The above settings can optionally be overridden using an environment file:
ENV_FILE=/run/coreos-kubernetes/options.env

TMPDIR=/var/tmp/
DOCKER_HOST=unix:///var/run/early-docker.sock
FLANNEL_VER=0.5.3
ETCD_SSL_DIR=/etc/ssl/etcd

# -------------

function init_config {
    local REQUIRED=( 'ADVERTISE_IP' 'ETCD_ENDPOINTS' 'CONTROLLER_ENDPOINT' 'DNS_SERVICE_IP' 'K8S_VER' )

    if [ -f $ENV_FILE ]; then
        export $(cat $ENV_FILE | xargs)
    fi

    if [ -z $ADVERTISE_IP ]; then
        export ADVERTISE_IP=$(awk -F= '/COREOS_PUBLIC_IPV4/ {print $2}' /etc/environment)
    fi

    for REQ in "${REQUIRED[@]}"; do
        if [ -z "$(eval echo \$$REQ)" ]; then
            echo "Missing required config value: ${REQ}"
            exit 1
        fi
    done
}

function init_templates {
    local TEMPLATE=/etc/systemd/system/kubelet.service
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/mkdir -p /etc/kubernetes/manifests
ExecStart=/usr/bin/kubelet \
  --api_servers=${CONTROLLER_ENDPOINT} \
  --register-node=true \
  --allow-privileged=true \
  --config=/etc/kubernetes/manifests \
  --hostname-override=${ADVERTISE_IP} \
  --cluster_dns=${DNS_SERVICE_IP} \
  --cluster_domain=cluster.local \
  --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml \
  --tls-cert-file=/etc/kubernetes/ssl/worker.pem \
  --tls-private-key-file=/etc/kubernetes/ssl/worker-key.pem \
  --pod-infra-container-image="shenshouer/pause:0.8.0" \
  --cadvisor-port=0
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
    }

    local TEMPLATE=/etc/systemd/system/flanneld.service
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Description=Network fabric for containers
Documentation=https://github.com/coreos/flannel
Requires=early-docker.service
After=etcd.service etcd2.service early-docker.service
Before=early-docker.target

[Service]
Type=notify
Restart=always
RestartSec=5
Environment="TMPDIR=/var/tmp/"
Environment="DOCKER_HOST=unix:///var/run/early-docker.sock"
Environment="FLANNEL_VER=0.5.3"
Environment="ETCD_SSL_DIR=/etc/ssl/etcd"
LimitNOFILE=40000
LimitNPROC=1048576
ExecStartPre=/sbin/modprobe ip_tables
ExecStartPre=/usr/bin/mkdir -p /run/flannel
ExecStartPre=/usr/bin/mkdir -p "${ETCD_SSL_DIR}"
ExecStartPre=/usr/bin/touch /run/flannel/options.env

ExecStart=/usr/libexec/sdnotify-proxy /run/flannel/sd.sock \
  /usr/bin/docker run --net=host --privileged=true --rm \
  --volume=/run/flannel:/run/flannel \
  --env=NOTIFY_SOCKET=/run/flannel/sd.sock \
  --env=AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID} \
  --env=AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY} \
  --env-file=/run/flannel/options.env \
  --volume=/usr/share/ca-certificates:/etc/ssl/certs:ro \
  --volume=${ETCD_SSL_DIR}:/etc/ssl/etcd:ro \
  shenshouer/flannel:${FLANNEL_VER} /opt/bin/flanneld --ip-masq=true

# Update docker options
ExecStartPost=/usr/bin/docker run --net=host --rm -v /run:/run \
  shenshouer/flannel:${FLANNEL_VER} \
  /opt/bin/mk-docker-opts.sh -d /run/flannel_docker_opts.env -i
EOF
    }

    local TEMPLATE=/etc/kubernetes/worker-kubeconfig.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Config
clusters:
- name: local
  cluster:
    certificate-authority: /etc/kubernetes/ssl/ca.pem
users:
- name: kubelet
  user:
    client-certificate: /etc/kubernetes/ssl/worker.pem
    client-key: /etc/kubernetes/ssl/worker-key.pem
contexts:
- context:
    cluster: local
    user: kubelet
  name: kubelet-context
current-context: kubelet-context
EOF
    }

    local TEMPLATE=/etc/kubernetes/manifests/kube-proxy.yaml
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
apiVersion: v1
kind: Pod
metadata:
  name: kube-proxy
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: kube-proxy
    image: shenshouer/hyperkube:$K8S_VER
    command:
    - /hyperkube
    - proxy
    - --master=${CONTROLLER_ENDPOINT}
    - --kubeconfig=/etc/kubernetes/worker-kubeconfig.yaml
    securityContext:
      privileged: true
    volumeMounts:
      - mountPath: /etc/ssl/certs
        name: "ssl-certs"
      - mountPath: /etc/kubernetes/worker-kubeconfig.yaml
        name: "kubeconfig"
        readOnly: true
      - mountPath: /etc/kubernetes/ssl
        name: "etc-kube-ssl"
        readOnly: true
  volumes:
    - name: "ssl-certs"
      hostPath:
        path: "/usr/share/ca-certificates"
    - name: "kubeconfig"
      hostPath:
        path: "/etc/kubernetes/worker-kubeconfig.yaml"
    - name: "etc-kube-ssl"
      hostPath:
        path: "/etc/kubernetes/ssl"
EOF
    }

    local TEMPLATE=/etc/flannel/options.env
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
FLANNELD_IFACE=$ADVERTISE_IP
FLANNELD_ETCD_ENDPOINTS=$ETCD_ENDPOINTS
EOF
    }

    local TEMPLATE=/etc/systemd/system/flanneld.service.d/40-ExecStartPre-symlink.conf.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Service]
ExecStartPre=/usr/bin/ln -sf /etc/flannel/options.env /run/flannel/options.env
EOF
    }

    local TEMPLATE=/etc/systemd/system/docker.service.d/40-flannel.conf
    [ -f $TEMPLATE ] || {
        echo "TEMPLATE: $TEMPLATE"
        mkdir -p $(dirname $TEMPLATE)
        cat << EOF > $TEMPLATE
[Unit]
Requires=flanneld.service
After=flanneld.service
EOF
    }

}

init_config
init_templates

systemctl stop update-engine; systemctl mask update-engine

systemctl daemon-reload
systemctl enable kubelet; systemctl start kubelet

