#!/bin/bash

QCOW2FUSE=~jwallis/bin/qcow2fuse.bash

if grep -q "release 7" /etc/system-release; then
    SFDISK="/auto/xos-ha/util-linux-2.36/sbin/sfdisk"
elif grep -q "release 8" /etc/system-release; then
    SFDISK="/auto/xos-ha/util-linux-2.38.1/sbin/sfdisk"
else
    echo "Unknown release: $(cat /etc/system-release)" 1>&2
    exit 1
fi       

if ! ((part=$1)); then
    echo "Partition index must be a +ve integer" 1>&2
    exit 1
fi

if ! ((expand=$2)); then
    echo "Bootflash expansion size must be an integer number of GB" 1>&2
    exit 1
fi
expand+="G" 

qcow2_file=$3
if ! [ -f "${qcow2_file}" ]; then
    echo "File not found: ${qcow2_file}" 1>&2
    exit 1
fi


function warn () {
    echo "$1" 1>&2
}

function die () {
    warn "$1"
    exit 1
}

function mnt_pt_hash_tmp () {
    qcow2_file=$1
    abs_file=$(readlink -f "${qcow2_file}")
    hash=$(md5sum <<< "$abs_file")

    hash="${hash%% *}"
    echo "${XDG_RUNTIME_DIR}/qcow2-expand.${hash}"
}

function cleanup () {
    if [ -e "${mnt_pt}" ]; then
        ${QCOW2FUSE} -u "${mnt_pt}"
        rmdir "${mnt_pt}" 2> /dev/null
    fi
}

trap cleanup EXIT

mnt_pt=$(mnt_pt_hash_tmp $qcow2_file)
mkdir -p ${mnt_pt}

${QCOW2FUSE} -o rawnbd "${qcow2_file}" "${mnt_pt}"

part_list=$(${SFDISK} -l "${mnt_pt}/nbd" | sed -nr "s#^${mnt_pt}/nbd([0-9]+).*#\1#p")

${QCOW2FUSE} -u "${mnt_pt}"

part_found=0
for p in ${part_list}; do
    if [ "$part_found" = 1 ]; then
        move_list="$p $move_list"
    fi
    if [ "$p" = "$part" ]; then
        part_found=1
    fi
done

if [ "${part_found}" = 0 ]; then
    die "Partition $part not found in ${qcow2_file}"
fi

#echo move_list=$move_list
#exit

qemu-img resize -f qcow2 "${qcow2_file}" +${expand}

${QCOW2FUSE} -o rawnbd "${qcow2_file}" "${mnt_pt}"

for p in $move_list; do
    echo "+${expand}" | ${SFDISK} --move-data -N$p "${mnt_pt}/nbd"
done

echo ", +" |  ${SFDISK} -N${part} "${mnt_pt}/nbd"
${QCOW2FUSE} -u "${mnt_pt}"

${QCOW2FUSE} -o rawnbd -p 4 "${qcow2_file}" "${mnt_pt}"
e2fsck -y -f "${mnt_pt}/nbd"
resize2fs "${mnt_pt}/nbd"
