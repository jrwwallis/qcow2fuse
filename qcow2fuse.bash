#!/bin/bash

# MIT License
# 
# Copyright (c) 2020 jrwwallis
# https://github.com/jrwwallis/qcow2fuse
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

if [ -z "${QEMU_NBD}" ]; then
    QEMU_NBD="qemu-nbd"
fi
if [ -z "${NBDFUSE}" ]; then
    NBDFUSE="nbdfuse"
fi
if [ -z "${FUSE2FS}" ]; then
    FUSE2FS="fuse2fs"
fi
if [ -z "${NTFS3G}" ]; then
    NTFS3G="ntfs-3g"
fi
if [ -z "${FUSERMOUNT}" ]; then
    FUSERMOUNT="fusermount"
fi
if [ -z "${PARTED}" ]; then
    PARTED="parted"
fi
if [ -z "${MOUNTPOINT}" ]; then
    MOUNTPOINT="mountpoint"
fi

delay=0.2

shopt -s nullglob

function warn () {
    echo "$1" 1>&2
}

function die () {
    warn "$1"
    exit 1
}

function usage () {
    msg=$1
    if [ "$msg" ]; then
	output="${msg}
"
    fi	
    output+="Usage: qcow2fuse.bash [-o fakeroot] [-o ro] [-o rawnbd] [-p PART_ID] imagefile mountpoint
"
    output+="       qcow2fuse.bash -u mountpoint
"
    output+="       qcow2fuse.bash -l imagefile
"
    die "$output"
}

function mnt_pt_hash_tmp () {
    mnt_pt=$1
    abs_mnt_pt=$(readlink -f "${mnt_pt}")
    hash=$(md5sum <<< "$abs_mnt_pt")

    hash="${hash%% *}"
    echo "${XDG_RUNTIME_DIR}/qcow2fuse.${hash}"
}

function qcow2_nbd_mount () {
    nbd_mnt=$1
    qcow_file=$2
    offset=$3
    size=$4
    
    if [ "${mnt_opts[ro]+x}" ]; then
	qemu_nbd_mode="--read-only"
	nbdfuse_mode="--readonly"
    fi

    image_opts="driver=raw"
    if [ "${offset}" -a "${size}" ]; then
	image_opts+=",offset=${offset}"
	image_opts+=",size=${size}"
    fi
    image_opts+=",file.file.filename=${qcow_file}"
    image_opts+=",file.driver=qcow2"

    grep -q ^user_allow_other /etc/fuse.conf
    if [ $? -eq 0 ]; then
        fuse_allow_other="-o allow_other"
    fi

    ${NBDFUSE} \
        $fuse_allow_other ${nbdfuse_mode} ${nbd_mnt} \
        --socket-activation ${QEMU_NBD} ${qemu_nbd_mode} \
        --image-opts "${image_opts}" 2>&1 | grep -v "Unexpected end-of-file before all bytes were read" &

    retries=0
    until [ -f "${nbd_mnt}/nbd" ]; do
	sleep $delay
	if ((++retries>10)); then
	    return 1
	fi
    done
}

function qcow2_nbd_unmount () {
    nbd_mnt=$1

    retries=0
    until ${FUSERMOUNT} -u ${nbd_mnt} 2> /dev/null; do
	sleep $delay
	if ((++retries>10)); then
	    warn "Can't unmount ${nbd_mnt}"
            break
	fi
    done
}

function get_part_params () {
    part_path=$1
    part_id=$2

    {
	# https://alioth-lists.debian.net/pipermail/parted-devel/2006-December/000573.html
	read
	IFS=: read path size type log_sec_sz phy_sec_sz tbl_type model_name
	case $tbl_type in
	loop)
	    if [ "${part_id}" ]; then
		die "Not a partitioned image"
	    else
		echo "Partition table: None"
		return
	    fi
	;;
	mbr|gpt|msdos)
	    if [ -z "${part_id}" ]; then
		echo "Partition table: $tbl_type"
		cat
		return
	    fi
	;;
	*)
	    die "Indeterminate partitioning $tbl_type"
	esac
	while IFS=: read index start end size fs_type name flags; do
	    if [  "${index}" == "${part_id}" ]; then
		if [[ ${fs_type} =~ ext[234] ]] || [[ ${fs_type} =~ ntfs.* ]]; then
		    part_start=${start%B}
		    part_size=${size%B}
		    break
		else
		    die "Unknown partition type ${fs_type}"
		fi
	    fi
	done
	if [ -z ${part_start} ]; then
	    die "Partition ${part_id} not found"
	fi
    } < <(${PARTED} --machine --script ${nbd_mnt}/nbd unit B print)

    echo "${part_start} ${part_size}" "${fs_type}"
}

function part_table_type () {
    part_path=$1
 
    {
	# https://alioth-lists.debian.net/pipermail/parted-devel/2006-December/000573.html
	read
	IFS=: read path size type log_sec_sz phy_sec_sz tbl_type model_name
    } < <(${PARTED} --machine --script ${nbd_mnt}/nbd unit B print)

    echo "${tbl_type}"
}

function qcow2_ext_mount () {
    nbd_mnt=$1
    
    if [ "${mnt_opts[ro]+x}" ]; then
	fuse2fs_mode="-o ro"
    fi

    if [ "${mnt_opts[fakeroot]+x}" ]; then
	fuse2fs_fakeroot="-o fakeroot"
    fi

    ${FUSE2FS} ${nbd_mnt}/nbd ${mnt_pt} ${fuse2fs_mode} ${fuse2fs_fakeroot} > /dev/null
    # fuse2fs return code appears to be unreliable.  Check mountpoint instead
    ${MOUNTPOINT} -q ${mnt_pt}
}

function qcow2_ntfs_mount () {
    nbd_mnt=$1

    if [ "${mnt_opts[ro]+x}" ]; then
	ntfs3g_mode="-o ro"
    fi

    ${NTFS3G} ${ntfs3g_mode} ${nbd_mnt}/nbd ${mnt_pt} >/dev/null
}

function qcow2_fs_unmount () {
    mnt_pt="$1"
    ${FUSERMOUNT} -u "${mnt_pt}"
    retries=0
    while ${MOUNTPOINT} -q "${mnt_pt}"; do
	sleep $delay
	if ((++retries>10)); then
	    warn "Can't unmount ${mnt_pt}"
            break
	fi
        ${FUSERMOUNT} -u "${mnt_pt}"
    done
}

function qcow2_mount_partition () {
    qcow_file=$1
    part_id=$2
    mnt_pt=$3
    
    if ${MOUNTPOINT} -q "${mnt_pt}"; then
	die "Mount point ${mnt_pt} already in use"
    fi

    nbd_mnt=$(mnt_pt_hash_tmp "${mnt_pt}")
    mkdir -p "${nbd_mnt}"

    if ${MOUNTPOINT} -q "${nbd_mnt}"; then
	die "${qcow_file} is already mounted"
    fi
    
    qcow2_nbd_mount "${nbd_mnt}" "${qcow_file}"
    if [ $? -ne 0 ]; then
	rm -rf "${nbd_mnt}"	
	die "Timed out mounting ${qcow_file}"
    fi

    params=$(get_part_params "${nbd_mnt}/nbd" "${part_id}")
    if [ "${params}" ]; then
	read offset size fstype <<< "${params}"
	qcow2_nbd_unmount "${nbd_mnt}"
    else
	qcow2_nbd_unmount "${nbd_mnt}"
	rm -rf "${nbd_mnt}"
	die "Partition ${part_id} not found in ${qcow_file}"
    fi
 
    if [ "${mnt_opts[rawnbd]+x}" ]; then
	qcow2_nbd_mount "${mnt_pt}" "${qcow_file}" "${offset}" "${size}"
	if [ $? -ne 0 ]; then
	    die "Timed out mounting ${qcow_file}"
	fi
	return
    fi

    qcow2_nbd_mount "${nbd_mnt}" "${qcow_file}" "${offset}" "${size}"
    if [ $? -ne 0 ]; then
	rm -rf "${nbd_mnt}"	
	die "Timed out mounting partition ${part_id} of ${qcow_file}"
    fi

    if [[ ${fstype} =~ ntfs.* ]]; then
        qcow2_ntfs_mount "${nbd_mnt}"
    else
        qcow2_ext_mount "${nbd_mnt}"
    fi

    if [ $? -ne 0 ]; then
	qcow2_nbd_unmount "${nbd_mnt}"
	rm -rf "${nbd_mnt}"
	die "Failed to mount partition ${part_id} to ${mnt_pt}"
    fi
}

function qcow2_mount () {
    qcow_file=$1
    mnt_pt=$2
    
    if ${MOUNTPOINT} -q "${mnt_pt}"; then
	die "Mount point ${mnt_pt} already in use"
    fi

    nbd_mnt=$(mnt_pt_hash_tmp "${mnt_pt}")
    mkdir -p "${nbd_mnt}"
    
    if ${MOUNTPOINT} -q "${nbd_mnt}"; then
	die "${qcow_file} is already mounted"
    fi
    
    if [ "${mnt_opts[rawnbd]+x}" ]; then
	qcow2_nbd_mount "${mnt_pt}" "${qcow_file}"
	if [ $? -ne 0 ]; then
	    die "Timed out mounting ${qcow_file}"
	fi
	return
    fi

    qcow2_nbd_mount "${nbd_mnt}" "${qcow_file}"
    if [ $? -ne 0 ]; then
	rm -rf "${nbd_mnt}"	
	die "Timed out mounting ${qcow_file}"
    fi

    tbl_type=$(part_table_type)
    case $tbl_type in
    loop)
    ;;
    mbr|gpt)
	qcow2_nbd_unmount "${nbd_mnt}"
	rm -rf "${nbd_mnt}"
        die "Is a ${tbl_type} partitioned image"
    ;;
    *)
	qcow2_nbd_unmount "${nbd_mnt}"
	rm -rf "${nbd_mnt}"
	die "Indeterminate partitioning"
    esac

    qcow2_ext_mount "${nbd_mnt}"
    if [ $? -ne 0 ]; then
	qcow2_nbd_unmount "${nbd_mnt}"
	rm -rf "${nbd_mnt}"
	die "Failed to mount to ${mnt_pt}"
    fi
}

function qcow2_unmount () {
    mnt_pt=$1

    nbd_mnt=$(mnt_pt_hash_tmp "${mnt_pt}")
    if ! [ -e "${nbd_mnt}" ]; then
	die "No temp dir found for mount point"
    fi
    
    qcow2_fs_unmount "${mnt_pt}"

    if [ -e "${nbd_mnt}/nbd" ]; then
	qcow2_nbd_unmount "${nbd_mnt}"
    fi

    rm -rf ${nbd_mnt}
}

function partition_list () {
    qcow_file=$1

    nbd_mnt=$(mnt_pt_hash_tmp "${mnt_pt}")
    mkdir -p "${nbd_mnt}"
    
    if ${MOUNTPOINT} -q "${nbd_mnt}"; then
	die "${qcow_file} is already mounted"
    fi
    
    qcow2_nbd_mount "${nbd_mnt}" "${qcow_file}"
    if [ $? -ne 0 ]; then
	rm -rf "${nbd_mnt}"	
	die "Timed out mounting ${qcow_file}"
    fi

    get_part_params "${nbd_mnt}"

    qcow2_nbd_unmount "${nbd_mnt}"

    rm -rf ${nbd_mnt}    
}

declare -A mnt_opts
op=mount
while getopts ":p:u:o:l:h" opt; do
    case ${opt} in
    p)
        part_id="$OPTARG"
        ;;
    u)
        op=unmount
	mnt_pt="$OPTARG"
        ;;
    o)
	mnt_opt="$OPTARG"
	mnt_opt_re="([^=]+)=(.*)"
	if [[ "$mnt_opt" =~ $mnt_opt_re ]]; then
	    mnt_opts[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
	else
	    mnt_opts[$mnt_opt]=""
	fi
	;;
    l)
        op=list
	qcow2_file="$OPTARG"
        ;;
    h)
        usage
        ;;
    \? )
      usage "Invalid option: $OPTARG"
      ;;
    : )
      usage "Invalid option: $OPTARG requires an argument"
      ;;
    esac
done
shift $((OPTIND -1))

case $op in
mount)
    qcow2_file=$1
    if [ -z "${qcow2_file}" ]; then
	usage
    fi
    mnt_pt=$2
    if [ -z "${mnt_pt}" ]; then
	usage
    fi
    if ! [ -w "${mnt_pt}" ]; then
	die "Directory ${mnt_pt} not writeable"
    fi
    mnt_pt_contents=(${mnt_pt}/*)
    if [ ${#mnt_pt_contents[@]} -ne 0 ]; then
	die "Directory ${mnt_pt} not empty"
    fi
    
    if [ "${part_id}" ]; then
	qcow2_mount_partition "${qcow2_file}" "${part_id}" "${mnt_pt}"
    else
	qcow2_mount "${qcow2_file}" "${mnt_pt}"
    fi
;;
unmount)
    qcow2_unmount "${mnt_pt}"
;;
list)
    partition_list "${qcow2_file}"
;;
*)
    die "Unsupported operation $op"
esac
