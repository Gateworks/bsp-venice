SHELL = /bin/sh

# SOC can be imx8mm|imx8mn|imx8mp
# Note that SOC is relevant for ATF and U-Boot but both buildroot and Linux
# support all variants with the imx8mm_venice_defconfig config file
SOC ?= imx8mm
ifeq ($(SOC), imx8mm)
SPL_OFFSET_KB=33
endif
ifeq ($(SOC), imx8mn)
SPL_OFFSET_KB=32
endif
ifeq ($(SOC), imx8mp)
SPL_OFFSET_KB=32
endif
ifeq ($(SPL_OFFSET_KB),)
$(error "Error: Unknown platform. Please use SOC=<imx8mm|imx8mn|imx8mp> to specify the platform")
endif

.PHONY: all
all: ubuntu-image

# Toolchain
.PHONY: toolchain
toolchain: buildroot/output/host/bin/aarch64-linux-gcc
buildroot/output/host/bin/aarch64-linux-gcc:
	$(MAKE) -C buildroot imx8mm_venice_defconfig
	$(MAKE) -C buildroot toolchain

# Buildroot
.PHONY: buildroot
buildroot:
	$(MAKE) -C buildroot imx8mm_venice_defconfig all

# ATF
.PHONY: atf
ATF_ARGS ?= PLAT=$(SOC)
atf: u-boot/bl31.bin
u-boot/bl31.bin: toolchain
	$(MAKE) -C atf $(ATF_ARGS) bl31
	ln -sf ../atf/build/$(SOC)/release/bl31.bin u-boot/

# ddr-firmware
DDR_FIRMWARE_URL:=https://www.nxp.com/lgfiles/NMG/MAD/YOCTO
DDR_FIRMWARE_VER:=firmware-imx-8.10
DDR_FIRMWARE_FILES := \
	lpddr4_pmu_train_1d_dmem.bin \
	lpddr4_pmu_train_1d_imem.bin \
	lpddr4_pmu_train_2d_dmem.bin \
	lpddr4_pmu_train_2d_imem.bin
ddr-firmware: $(DDR_FIRMWARE_VER)/firmware/ddr/synopsys
$(DDR_FIRMWARE_VER)/firmware/ddr/synopsys:
	wget -N $(DDR_FIRMWARE_URL)/$(DDR_FIRMWARE_VER).bin
	$(SHELL) $(DDR_FIRMWARE_VER).bin --auto-accept
	for file in $(DDR_FIRMWARE_FILES); do ln -s ../$@/$${file} u-boot/; done

# Gateworks tool for creating binaries for jtag_usbv4
mkimage_jtag:
	wget -N http://dev.gateworks.com/jtag/mkimage_jtag
	chmod +x mkimage_jtag

# uboot
.PHONY: uboot
uboot: u-boot/flash.bin
u-boot/flash.bin: toolchain atf ddr-firmware mkimage_jtag
	$(MAKE) -C u-boot imx8mm_venice_defconfig
	$(MAKE) -C u-boot flash.bin
	$(MAKE) CROSS_COMPILE= -C u-boot imx8mm_venice_defconfig envtools
	ln -sf fw_printenv u-boot/tools/env/fw_setenv
	./mkimage_jtag --emmc -s \
		u-boot/flash.bin@user:erase_none:$(shell expr $(SPL_OFFSET_KB) \* 2)-32640 > venice-$(SOC)_u-boot_spl.bin

# kernel
.PHONY: linux
linux: linux/arch/arm64/boot/Image
linux/arch/arm64/boot/Image: toolchain
	$(MAKE) -C linux imx8mm_venice_defconfig
	$(MAKE) DTC_FLAGS="-@" -C linux Image dtbs modules
.PHONY: kernel_image
kernel_image: linux-venice.tar.xz
linux-venice.tar.xz: linux/arch/arm64/boot/Image
	# install dir
	rm -rf linux/install
	mkdir -p linux/install/boot
	# install uncompressed kernel
	cp linux/arch/arm64/boot/Image linux/install/boot
	# install a compressed kernel in a kernel.itb
	gzip -fk linux/arch/arm64/boot/Image
	u-boot/tools/mkimage -f auto -A $(ARCH) \
		-O linux -T kernel -C gzip \
		-a $(LOADADDR) -e $(LOADADDR) -n "Kernel" \
		-d linux/arch/arm64/boot/Image.gz linux/install/boot/kernel.itb
	# install dtbs
	cp linux/arch/arm64/boot/dts/freescale/imx8*-venice-*.dtb* linux/install/boot
	# install kernel modules
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=install modules_install
	make -C linux INSTALL_HDR_PATH=install/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../linux/install \
		INSTALL_MOD_PATH=../linux/install install
	# newracom nrc7292 802.11ah driver
	make -C nrc7292/package/host/src/nrc/ KDIR=$(PWD)/linux modules
	make -C nrc7292/package/host/src/nrc/ KDIR=$(PWD)/linux \
		INSTALL_MOD_PATH=$(PWD)/linux/install modules_install
	# neramcom nrc7292 firmware
	mkdir -p linux/install/lib/firmware
	cp nrc7292/package/host/evk/sw_pkg/nrc_pkg/sw/firmware/nrc7292_* \
		linux/install/lib/firmware/
	# newracom nrc7292 cli app
	make -C nrc7292/package/host/src/cli_app/
	mkdir -p linux/install/usr/local/bin/
	cp nrc7292/package/host/src/cli_app/cli_app \
		linux/install/usr/local/bin/
	# FTDI USB-SPI driver
	make -C ftdi-usb-spi \
		KDIR=$(PWD)/linux INSTALL_MOD_PATH=$(PWD)/linux/install \
		INSTALL_MOD_STRIP=1 \
		modules modules_install
	# tarball
	tar -cvJf linux-venice.tar.xz --numeric-owner --owner=0 --group=0 \
		-C linux/install .

# ubuntu
UBUNTU_FSSZMB ?= 1800
UBUNTU_REL ?= focal
UBUNTU_FS ?= $(UBUNTU_REL)-venice.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-venice-$(SOC).img
$(UBUNTU_REL)-venice.tar.xz:
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_REL)-venice.tar.xz
$(UBUNTU_FS): linux-venice.tar.xz $(UBUNTU_REL)-venice.tar.xz
	# root filesystem
	sudo ./venice/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_REL)-venice.tar.xz linux-venice.tar.xz
.PHONY: ubuntu-image
ubuntu-image: u-boot/flash.bin linux/arch/arm64/boot/Image $(UBUNTU_FS) mkimage_jtag
	# create U-Boot bootscript
	$(eval TMP=$(shell mktemp -d -t tmp.XXXXXX))
	sudo mount $(UBUNTU_FS) $(TMP)
	sudo u-boot/tools/mkimage -A $(ARCH) -T script -C none \
		-d venice/boot.scr $(TMP)/boot/boot.scr
	sudo umount $(TMP)
	# disk image
	truncate -s $$(($(UBUNTU_FSSZMB) + 16))M $(UBUNTU_IMG)
	dd if=u-boot/flash.bin of=$(UBUNTU_IMG) bs=1k seek=$(SPL_OFFSET_KB) oflag=sync
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=1M seek=16
	# partition table
	printf "$$((16*2*1024)),,L,*" | sfdisk -uS $(UBUNTU_IMG)
	# default U-Boot env
	$(eval TMP := $(shell mktemp))
	sed s/firmware.img/$(UBUNTU_IMG)/ venice/fw_env.config > $(TMP)
	cat $(TMP)
	u-boot/tools/env/fw_setenv --lock venice/. --config $(TMP) --script venice/venice.env
	rm $(TMP)
	# create boot-firmware only image
	dd if=$(UBUNTU_IMG) of=firmware-venice.img bs=1M count=16
	./mkimage_jtag --emmc -e --partconf=user firmware-venice.img@user:erase_all:0-32640 \
		> firmware-venice-$(SOC).bin
	# compress
	gzip -f $(UBUNTU_IMG)

.PHONY: clean
clean:
	make -C u-boot clean
	make -C atf $(ATF_ARGS) clean
	make -C linux clean
	make -C cryptodev-linux clean
	make -C buildroot clean
	rm -rf linux/install
	rm -rf $(DDR_FIRMWARE_VER)*
	rm -rf u-boot/lpddr4_pmu_*.bin
	rm -rf linux-venice.tar.xz
	rm -rf focal-venice.ext4 focal-venice.img.gz focal-venice.tar.xz

.PHONY: distclean
distclean:
	make -C u-boot distclean
	make -C atf $(ATF_ARGS) distclean
	make -C linux distclean
	make -C buildroot distclean
	rm -rf linux/install
	rm -rf $(DDR_FIRMWARE_VER)
