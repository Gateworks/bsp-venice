SHELL = /bin/sh

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
ATF_ARGS ?= PLAT=imx8mm
atf: u-boot/bl31.bin
u-boot/bl31.bin: toolchain
	$(MAKE) -C atf $(ATF_ARGS) bl31
	ln -sf ../atf/build/imx8mm/release/bl31.bin u-boot/

# ddr-firmware
DDR_FIRMWARE_URL:=https://www.nxp.com/lgfiles/NMG/MAD/YOCTO
DDR_FIRMWARE_VER:=firmware-imx-8.0
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

# uboot
.PHONY: uboot
uboot: u-boot/flash.bin
u-boot/flash.bin: toolchain atf ddr-firmware
	$(MAKE) -C u-boot imx8mm_venice_defconfig
	$(MAKE) -C u-boot flash.bin
	$(MAKE) CROSS_COMPILE= -C u-boot envtools
	ln -sf fw_printenv u-boot/tools/env/fw_setenv

# kernel
.PHONY: linux
linux: linux/arch/arm64/boot/Image
linux/arch/arm64/boot/Image: toolchain
	$(MAKE) -C linux imx8mm_venice_defconfig
	$(MAKE) -C linux Image modules
.PHONY: kernel_image
kernel_image: linux-venice.tar.xz
linux-venice.tar.xz: linux/arch/arm64/boot/Image
	# install dir
	rm -rf linux/install
	mkdir -p linux/install/boot
	# install uncompressed kernel
	cp linux/arch/arm64/boot/Image linux/install/boot
	# also install a compressed kernel in a kernel.itb
	gzip -fk linux/arch/arm64/boot/Image
	u-boot/tools/mkimage -f auto -A $(ARCH) \
		-O linux -T kernel -C gzip \
		-a $(LOADADDR) -e $(LOADADDR) -n "Kernel" \
		-d linux/arch/arm64/boot/Image.gz linux/install/boot/kernel.itb
	# install kernel modules
	make -C linux INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=install modules_install
	make -C linux INSTALL_HDR_PATH=install/usr headers_install
	# cryptodev-linux build/install
	make -C cryptodev-linux KERNEL_DIR=../linux
	make -C cryptodev-linux KERNEL_DIR=../linux DESTDIR=../linux/install \
		INSTALL_MOD_PATH=../linux/install install
	# cypress brcmfmac driver
	make -C cyw-fmac KLIB=$(PWD)/linux KLIB_BUILD=$(PWD)/linux defconfig-brcmfmac
	chmod +x $(PWD)/cyw-fmac/scripts/make
	make -C cyw-fmac KLIB=$(PWD)/linux KLIB_BUILD=$(PWD)/linux modules
	make -C $(PWD)/linux M=$(PWD)/cyw-fmac INSTALL_MOD_PATH=$(PWD)/linux/install modules_install
	# wireguard-linux-compat build/install
	make -C $(PWD)/linux M=$(PWD)/wireguard-linux-compat/src modules
	make -C $(PWD)/linux M=$(PWD)/wireguard-linux-compat/src INSTALL_MOD_PATH=$(PWD)/linux/install modules_install
	# tarball
	tar -cvJf linux-venice.tar.xz --numeric-owner -C linux/install .

# ubuntu
UBUNTU_FSSZMB ?= 1536
UBUNTU_REL ?= focal
UBUNTU_FS ?= $(UBUNTU_REL)-venice.ext4
UBUNTU_IMG ?= $(UBUNTU_REL)-venice.img
$(UBUNTU_REL)-venice.tar.xz:
	wget -N http://dev.gateworks.com/ubuntu/$(UBUNTU_REL)/$(UBUNTU_REL)-venice.tar.xz
.PHONY: ubuntu-image
ubuntu-image: u-boot/flash.bin linux/arch/arm64/boot/Image linux-venice.tar.xz \
   	      $(UBUNTU_REL)-venice.tar.xz
	$(eval TMPDIR := $(shell mktemp -d))
	$(eval TMP := $(shell mktemp))
	mkdir -p $(TMPDIR)/boot
	# create kernel.itb with compressed kernel image
	gzip -fk linux/arch/arm64/boot/Image
	u-boot/tools/mkimage -f auto -A $(ARCH) \
		-O linux -T kernel -C gzip \
		-a $(LOADADDR) -e $(LOADADDR) -n "Ubuntu $(UBUNTU_REL)" \
		-d linux/arch/arm64/boot/Image.gz $(TMPDIR)/boot/kernel.itb
	# create U-Boot bootscript
	u-boot/tools/mkimage -A $(ARCH) -T script -C none \
		-d venice/boot.scr $(TMPDIR)/boot/boot.scr
	# root filesystem
	sudo ./venice/mkfs ext4 $(UBUNTU_FS) $(UBUNTU_FSSZMB)M \
		$(UBUNTU_REL)-venice.tar.xz linux-venice.tar.xz $(TMPDIR)
	rm -rf $(TMPDIR)
	# disk image
	truncate -s $$(($(UBUNTU_FSSZMB) + 16))M $(UBUNTU_IMG)
	dd if=u-boot/flash.bin of=$(UBUNTU_IMG) bs=1k seek=33 oflag=sync
	dd if=$(UBUNTU_FS) of=$(UBUNTU_IMG) bs=1M seek=16
	# partition table
	printf "$$((16*2*1024)),,L,*" | sfdisk -uS $(UBUNTU_IMG)
	# default U-Boot env
	$(eval TMP := $(shell mktemp))
	sed s/firmware.img/$(UBUNTU_IMG)/ venice/fw_env.config > $(TMP)
	cat $(TMP)
	u-boot/tools/env/fw_setenv --lock venice/. --config $(TMP) --script venice/venice.env
	rm $(TMP)
	# compress
	gzip -f $(UBUNTU_IMG)

.PHONY: clean
clean:
	make -C u-boot clean
	make -C atf $(ATF_ARGS) clean
	make -C linux clean
	make -C cryptodev-linux clean
	make -C cyw-fmac KLIB=$(PWD)/linux KLIB_BUILD=$(PWD)/linux clean
	make -C wireguard-linux-compat/src clean
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
