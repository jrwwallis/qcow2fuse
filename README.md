# qcow2fuse
FUSE userspace mounting of .qcow2 images 

<pre>
Usage: qcow2fuse.bash [-o fakeroot] [-o ro] [-p PART_ID] imagefile mountpoint
       qcow2fuse.bash -u mountpoint
       qcow2fuse.bash -l imagefile
</pre>

Supports read-write and read-only modes.

Supports .qcow2 files with backing files.

qcow2fuse uses [qemu-nbd](https://manpages.debian.org/testing/qemu-utils/qemu-nbd.8.en.html) and [nbdfuse](https://libguestfs.org/nbdfuse.1.html) first to mount the whole .qcow2 image to a temporary location.  It then checks the mounted image for partitions using [parted](https://www.gnu.org/software/parted/manual/parted.html):
- if it is a non-partitioned image and partition ID was not specified with `-p`, qcow2fuse goes ahead and mounts the whole image to the specified mount point using [fuse2fs](http://manpages.ubuntu.com/manpages/bionic/man1/fuse2fs.1.html).
- if it is a partitioned image, and the specified partition ID (`-p`) matches an existing partition, then the offset and size of that partition are noted, then the initial qemu-nbd/nbdfuse mount is unmounted, then remounted using just the discovered offset and size to the temporary location.  This raw partition is then mounted to the specified mount point using fuse2fs.

`-u` unmounts an existing mountpoint, as well as the qemu-nbd/nbdfuse mount at a temporary location.

`-l` lists partitions, or lack thereof, discovered in the .qcow2 image.

`-o ro` mounts the image read-only

`-o fakeroot` allows non-privileged access to files in the disk image that are owned by user 0 (root)

### Dependencies

1. FUSE.  FUSE support must be in the kernel, such that `/dev/fuse` has read-write permissions for all users.  Also libfuse.so and fusermount must be available
2. qemu-nbd.  This binary exports a .qcow2 file as a read-write [NBD](https://en.wikipedia.org/wiki/Network_block_device), in this case via a unix socket
3. nbdfuse.  This binary takes the NBD exported by qemu-nbd and FUSE mounts it to the filesystem
4. parted.  parted was chosen over fdisk and gdisk for a couple of reasons:
  - It supports both MBR and GPT partition tables
  - It can provide output in machine-readable format
5. fuse2fs.  This binary takes a raw disk image and FUSE mounts it to the filesystem.  In this case, the raw disk image is the one provided by the nbdfuse/qemu-nbd mount.

The dependencies are all easily satisfied in Ubuntu 20.04.1.  In particular, full FUSE support is already present, as is GNU parted.  qemu-nbd, nbdfuse and fuse2fs may all easily be installed with the apt package manager:

<pre>
sudo apt install qemu-utils
sudo apt install nbdfuse
sudo apt install fuse2fs
</pre>

If sudo access for apt is not available, these dependencies are all buildable from source, without further dependencies.

By default, the script will use the first instances of qemu-nbd, nbdfuse, fuse2fs, fusermount, parted and mountpoint binaries that it finds in the `$PATH` environment variable.  However these may be overriden by exporting `$QEMU_NBD`, `$NBDFUSE`, `$FUSE2FS`, `$FUSERMOUNT`, `$PARTED` and `$MOUNTPOINT` respective environment variables giving the required path to the appropriate binaries.
