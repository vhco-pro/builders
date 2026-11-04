PACKER ?= packer

.PHONY: init check
init:
	cd packer/ubuntu && $(PACKER) init .

check:
	$(PACKER) fmt -check -recursive packer/ubuntu
	cd packer/ubuntu && PKR_VAR_proxmox_api_token=validation-only-placeholder $(PACKER) validate .
	shellcheck -S warning packer/ubuntu/scripts/*.sh packer/ubuntu/tests/*.sh
	python3 -B -m unittest discover -s packer/ubuntu/tests -v
