export COMPUTE=gpu
export ID=1
export INSTANCE=instance-${ID}-${COMPUTE}
export BOOT_DISK_SIZE=150
export BOOT_DISK_TYPE=pd-balanced

include .env 
# (example of .env file)
#	export ACCOUNT=abc@developer.gserviceaccount.co
#   export PROJECT=happy-camper
#	export ZONE=us-central1-f
#	export FORWARD_PORTS = 1234
#	export GOOGLE_STORAGE=gs://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

# Makefile hacking
empty :=
space := $(empty) $(empty)
comma := ,

REMOTE=ssh ${INSTANCE}

.PHONY: help 
.PHONY: set-zone
.PHONY: create-instance start-instance stop-instance
.PHONY: forward-ports peek-forward-ports capture-forward-ports kill-forward-ports
.PHONY: update-config nvidia-smi nvidia-smi-fix

help:: # show help
	@echo usage:
	@echo   make _CMD_ or make _CMD_ COMPUTE=cpu or  make _CMD_ COMPUTE=gpu
	@echo names of commands:
	@echo  set-*: set something \(like zone\)
	@echo  create-*: create something
	@echo  install-*: install something
	@echo  build-*: build something \(download things, compile thing\)
	@echo  run-*: run something, perhaps in background
	@echo  status-*: find out some information
	@echo  help-*: get information about commands

	@echo
	@echo make targets:
	@echo
	@grep -E "^[[:alnum:]_-]+:" Makefile


set-zone:: # set zone
	gcloud config set compute/zone ${ZONE}

ifeq (${COMPUTE}, gpu)
SCOPE_PREFIX = https://www.googleapis.com/auth/
# TODO: Should this be devstorage.read_write ?
SCOPES = \
	devstorage.full_control \
	logging.write \
	monitoring.write \
	service.management.readonly \
	servicecontrol \
	trace.append
# The resource 'projects/ml-images/global/images/c0-deeplearning-common-gpu-v20240605-debian-11-py310' is deprecated. 
# A suggested replacement is 'projects/ml-images/global/images/c0-deeplearning-common-gpu-v20240613-debian-11-py310'.
DISK_OPTIONS = \
	auto-delete=yes \
	boot=yes \
	device-name=${INSTANCE} \
	image=projects/ml-images/global/images/c0-deeplearning-common-gpu-v20240605-debian-11-py310 \
	mode=rw \
	size=${BOOT_DISK_SIZE} \
	type=${BOOT_DISK_TYPE}
endif


create-instance: # create a remote instance
ifeq (${COMPUTE}, gpu)
	gcloud compute instances create ${INSTANCE} \
		--project=${PROJECT} \
		--zone=${ZONE} \
		--machine-type=g2-standard-12 \
		--network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
		--maintenance-policy=TERMINATE \
		--provisioning-model=STANDARD \
		--service-account=${ACCOUNT}\
		--scopes=$(subst $(space),$(comma),$(addprefix $(SCOPE_PREFIX),$(SCOPES))) \
		--accelerator=count=1,type=nvidia-l4 \
		--create-disk=$(subst $(space),$(comma),$(DISK_OPTIONS)) \
		--no-shielded-secure-boot \
		--shielded-vtpm \
		--shielded-integrity-monitoring \
		--labels=goog-ec-src=vm_add-gcloud \
		--reservation-affinity=any
else
	@echo "not supported (yet)""
endif
	make update-config
# first time, just ssh in to see if it works
	${REMOTE}


####################################################################################
# Port forwarding
####################################################################################

PORT_SESSION=background-ports

forward-ports::
	tmux new-session -d -s ${PORT_SESSION} \
		"gcloud compute ssh ${INSTANCE} -- $(foreach item,$(FORWARD_PORTS), -NL $(item):localhost:$(item))"
	sleep 3
	make peek-forward-ports

peek-forward-ports::
	lsof -nP -w | grep LISTEN | grep 127.0 

capture-forward-ports::
	tmux capture-pane -t ${PORT_SESSION} -p

kill-forward-ports::
	-tmux kill-session -t ${PORT_SESSION} 

####################################################################################
# starting and stopping instances
####################################################################################


stop-instance:: kill-forward-ports
	gcloud compute instances stop ${INSTANCE} --quiet

start-instance::
	gcloud compute instances start ${INSTANCE} --quiet
	sleep 10
	make update-config
	make nvidia-smi
	make forward-ports

update-config::
	cp -f ~/.ssh/config ~/.ssh/config.BACKUP
	gcloud compute config-ssh --remove
	gcloud compute config-ssh 
	sed -i '' -e '/\.us-/ s/\.us-.*$$//' ~/.ssh/config
	grep "Host instance" ~/.ssh/config

nvidia-smi::
	${REMOTE} nvidia-smi
	echo sudo apt-get install linux-headers-"`uname -r`"
	echo suggestion: make nvidia-smi-fix

nvidia-smi-fix::
	${REMOTE} sudo apt-get install linux-headers-"`uname -r`"
	make stop-instance
	make start-instance

#############################################################################
# Ollama 
#############################################################################

install-ollama::
	${REMOTE} "mkdir -p ollama"
	${REMOTE} "curl https://ollama.ai/install.sh > ollama/install.sh"
	${REMOTE} "sh ollama/install.sh"
	${REMOTE} -t -t "ollama pull mistral"
	${REMOTE} -t -t "ollama run mistral Say hi and nothing else"

start-ollama:
	gcloud compute ssh ${USER}@${INSTANCE} --command "ollama list"

