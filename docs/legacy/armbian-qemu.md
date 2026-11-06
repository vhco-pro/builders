# Legacy Armbian QEMU recipes

These ARM commands were kept from the original Packer README. They are manual recipes for separately
prepared Armbian images. They are outside the validated Ubuntu amd64 image matrix.

## Boot an ARM64 raw image

```bash
sudo qemu-system-aarch64 -m 2048 -cpu cortex-a72 \
  -M virt \
  -drive file=/path/to/armbian-image.img,format=raw \
  -serial mon:stdio \
  -netdev user,id=user.0 \
  -device virtio-net,netdev=user.0,romfile=
```

This retains the historical command. The image must provide a boot chain compatible with QEMU's
`virt` machine; CPU architecture alone is not enough. It is not a tested boot command for the current
Ubuntu output. A separately prepared UEFI or kernel boot flow may be needed for a different image.

## Extract a board image's U-Boot

The historical image used a partition offset of 16777216 bytes. Confirm the partition layout with
`fdisk -l` before selecting an offset for another image:

```bash
sudo mkdir -p /mnt/armbian
sudo mount -o loop,ro,offset=16777216 /path/to/armbian-image.img /mnt/armbian
sudo cp /mnt/armbian/boot/u-boot.bin ./
sudo umount /mnt/armbian
```

The old example invoked that extracted firmware as follows:

```bash
qemu-system-aarch64 \
  -machine virt -cpu cortex-a72 -m 2048 \
  -serial stdio \
  -bios ./u-boot.bin \
  -drive if=none,file=/path/to/armbian-image.qcow2,id=mydisk \
  -device ich9-ahci,id=ahci \
  -device ide-hd,drive=mydisk,bus=ahci.0
```

The firmware, storage controller and image need to agree. This historical combination has not been
revalidated here. Keep the original disk unchanged and use a copy while investigating it.

## References

- [Original Armbian QEMU discussion](https://forum.armbian.com/topic/38258-running-self-build-image-on-qemu-arm64/)
- [Original ARM64 examples](https://gist.github.com/wuhanstudio/e9b37b07312a52ceb5973aacf580c453)
- [QEMU ARM virt machine](https://www.qemu.org/docs/master/system/arm/virt.html)
