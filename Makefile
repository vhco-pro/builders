PACKER ?= packer

RECIPE ?= default

.PHONY: init check check-config check-shell check-tests check-image check-instance
init:
	cd packer/ubuntu && $(PACKER) init .

check: check-config check-shell check-tests
	@echo 'SKIP: real image builds, artifact inspection and fresh-instance checks require explicit disposable resources.'

check-config:
	$(PACKER) fmt -check -recursive packer/ubuntu
	cd packer/ubuntu && PKR_VAR_proxmox_api_token=validation-only-placeholder $(PACKER) validate .
check-shell:
	shellcheck -S warning packer/ubuntu/scripts/*.sh packer/ubuntu/tests/*.sh packer/ubuntu/recipes/*.sh

check-tests:
	python3 -B -m unittest discover -s packer/ubuntu/tests -v

check-image:
	bash packer/ubuntu/scripts/check-image.sh "$(IMAGE)" "$(RECIPE)" "$(PDS_VERSION)"

check-instance:
	bash packer/ubuntu/scripts/check-instance.sh "$(RECIPE)"
