#!/bin/bash
set -euo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

INSTANCE_PREFIX="${NAMESPACE}"-"${JOB_NAME_HASH}"
BUNDLE=crc_libvirt_"${BUNDLE_VERSION}".crcbundle

mkdir -p "${HOME}"/.ssh
mock-nss.sh

# gcloud compute will use this key rather than create a new one
cp "${CLUSTER_PROFILE_DIR}"/ssh-privatekey "${HOME}"/.ssh/google_compute_engine
chmod 0600 "${HOME}"/.ssh/google_compute_engine
cp "${CLUSTER_PROFILE_DIR}"/ssh-publickey "${HOME}"/.ssh/google_compute_engine.pub

# Copy pull secret to user home
cp "${CLUSTER_PROFILE_DIR}"/pull-secret "${HOME}"/pull-secret

gcloud auth activate-service-account --quiet --key-file "${CLUSTER_PROFILE_DIR}"/gce.json
gcloud --quiet config set project "${GOOGLE_PROJECT_ID}"
gcloud --quiet config set compute/zone "${GOOGLE_COMPUTE_ZONE}"
gcloud --quiet config set compute/region "${GOOGLE_COMPUTE_REGION}"

cat  > "${HOME}"/run-tests.sh << 'EOF'
#!/bin/bash
set -euo pipefail
export PATH=/home/packer:$PATH
mkdir -p /tmp/artifacts

function run-tests() {
  pushd crc
  set +e
  export PULL_SECRET_FILE=--pull-secret-file="${HOME}"/pull-secret
  export BUNDLE_LOCATION=--bundle-location="${HOME}"/$(cat "${HOME}"/bundle)
  export CRC_BINARY=--crc-binary=/tmp/
  make integration
  if [[ $? -ne 0 ]]; then
    exit 1
    popd
  fi
  popd
}

run-tests
EOF

chmod +x "${HOME}"/run-tests.sh

# Get the bundle
curl -L "https://storage.googleapis.com/crc-bundle-github-ci/crc_libvirt_${BUNDLE_VERSION}.zip" -o "${HOME}"/bundle.zip
unzip -P "$(cat /var/run/bundle-secret/secret.txt)"  "${HOME}"/bundle.zip -d  "${HOME}"

echo "${BUNDLE}" > "${HOME}"/bundle

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/run-tests.sh packer@"${INSTANCE_PREFIX}":~/run-tests.sh

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/pull-secret packer@"${INSTANCE_PREFIX}":~/pull-secret

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /bin/crc packer@"${INSTANCE_PREFIX}":/tmp/crc

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/bundle packer@"${INSTANCE_PREFIX}":~/bundle

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse "${HOME}"/"${BUNDLE}" packer@"${INSTANCE_PREFIX}":~/"${BUNDLE}"

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute scp \
  --quiet \
  --project "${GOOGLE_PROJECT_ID}" \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  --recurse /opt/crc packer@"${INSTANCE_PREFIX}":~/crc

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command 'sudo yum install -y podman make'

LD_PRELOAD=/usr/lib64/libnss_wrapper.so gcloud compute --project "${GOOGLE_PROJECT_ID}" ssh \
  --zone "${GOOGLE_COMPUTE_ZONE}" \
  packer@"${INSTANCE_PREFIX}" \
  --command '/home/packer/run-tests.sh'