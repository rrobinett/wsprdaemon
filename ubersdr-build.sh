#!/bin/bash
### Builds the ubersdr_wsprd wsprd and jt9 (github.com/madpsy/ubersdr_wsprd) from source for this CPU, checks them byte for byte
### against WSJT-X's stored outputs with the repo's own scripts, and only then installs them as bin/wsprd-ubersdr and
### bin/jt9-ubersdr.  Started detached by start_ubersdr_build() in wd-setup.sh; see the comments there.
###
### Usage: ubersdr-build.sh GIT_URL COMMIT SRC_DIR BIN_DIR BUILD_KEY LOG_FILE

declare git_url=$1 commit=$2 src_dir=$3 bin_dir=$4 build_key=$5 log_file=$6
exec >> ${log_file} 2>&1

function log() {
    echo -e "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

### Record the failure under this build key, so WD doesn't rebuild and fail again on every start
function fail() {
    log "ERROR: $*, so nothing was installed and WD keeps using the WSJT-X decoders"
    echo "${build_key}" > ${bin_dir}/ubersdr.failed
    exit 1
}

log "building '${build_key}' from ${git_url}"

if [[ ! -d ${src_dir}/.git ]]; then
    rm -rf ${src_dir}
    timeout 300 git clone -q ${git_url} ${src_dir} || fail "'git clone ${git_url}' failed"
fi
if ! git -C ${src_dir} cat-file -e ${commit}^{commit} 2>/dev/null ; then
    timeout 300 git -C ${src_dir} fetch -q origin || fail "'git fetch' in ${src_dir} failed"
fi
git -C ${src_dir} checkout -q --detach ${commit} || fail "'git checkout ${commit}' failed"

### x86: -march=native.  The vector code is under #if __AVX2__, so a CPU without AVX2 gets the plain code, which decodes the
### same, only slower.  WSPRD_X86_ARCH is ignored on ARM, where NEON is always there (and a 32 bit Pi builds the plain code).
declare build_dir=${src_dir}/build-wd
rm -rf ${build_dir}
cmake -S ${src_dir} -B ${build_dir} -DCMAKE_BUILD_TYPE=Release -DWSPRD_X86_ARCH=native > ${build_dir}.cmake.log 2>&1 \
    || fail "cmake failed:\n$(tail -20 ${build_dir}.cmake.log)"
/usr/bin/time -f "%e s" cmake --build ${build_dir} -j $(nproc) > ${build_dir}.make.log 2>&1 \
    || fail "the build failed:\n$(tail -20 ${build_dir}.make.log)"
log "built in $(tail -1 ${build_dir}.make.log): $(${build_dir}/wsprd --version)"

### The repo's checks against WSJT-X's stored outputs (the quick half of its './build.sh --check').  Each exits non-zero
### if any case differs.  On arm64 jt9's known FFTW NEON rounding differences are listed in the repo and pass as "accepted".
declare work_dir=$(mktemp -d)
trap "rm -rf ${work_dir}" EXIT
${src_dir}/scripts/wsprd-stored-check.sh ${build_dir}/wsprd ${work_dir}/wsprd > ${work_dir}/wsprd-check.log 2>&1 \
    || fail "wsprd failed its checks:\n$(tail -20 ${work_dir}/wsprd-check.log)"
log "$(tail -1 ${work_dir}/wsprd-check.log)"
${src_dir}/scripts/jt9-wine-check.sh ${build_dir}/jt9 ${work_dir}/jt9 > ${work_dir}/jt9-check.log 2>&1 \
    || fail "jt9 failed its checks:\n$(tail -20 ${work_dir}/jt9-check.log)"
log "$(tail -1 ${work_dir}/jt9-check.log)"

### Install by rename, so a decoder starting at this moment runs the old file or the new one, never half of one.  The stamp
### is written last: it is what tells WD these binaries are ready.
declare name
for name in wsprd jt9; do
    cp ${build_dir}/${name} ${bin_dir}/${name}-ubersdr.new && strip ${bin_dir}/${name}-ubersdr.new \
        && mv ${bin_dir}/${name}-ubersdr.new ${bin_dir}/${name}-ubersdr || fail "can't install ${bin_dir}/${name}-ubersdr"
done
rm -f ${bin_dir}/ubersdr.failed
echo "${build_key}" > ${bin_dir}/ubersdr.stamp
log "installed ${bin_dir}/wsprd-ubersdr and ${bin_dir}/jt9-ubersdr"
