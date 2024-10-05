export COMPUTE=gpu
export ID=1
export INSTANCE=instance-${ID}-${COMPUTE}
export BOOT_DISK_SIZE=200
export BOOT_DISK_TYPE=pd-balanced

include .env 
# (example of .env file)
#	export ACCOUNT=abc@developer.gserviceaccount.co
#   export PROJECT=happy-camper
#	export FORWARD_PORTS = 1234
#	export GOOGLE_STORAGE=gs://xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#	export REMOTE_USER=andy

include .zone
# (example of .zone file)
#	export ZONE=us-central1-a

export REGION=$(shell echo $(ZONE) | cut -d'-' -f1,2)

# Makefile hacking
empty :=
space := $(empty) $(empty)
comma := ,

REMOTE=ssh ${INSTANCE}

CONDA_BIN=/opt/conda/bin
REMOTE_PYTHON=${CONDA_BIN}/python3.10
SET_CONDA_BIN=export PATH="${CONDA_BIN}:$${PATH}"

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

list-instances::
	gcloud compute instances list

find-zone::
	@echo "Trying to find a working g2-standard-16 in US ZONE"
	@ZONES=$$(gcloud compute machine-types list | grep us- | grep g2-standard-16 | awk '{print $$2}' | sort -u | tr '\n' ' '); \
	ZONE_COUNT=$$(echo $$ZONES | wc -w); \
	echo Found $$ZONE_COUNT candidiate ZONES in US; \
	for zone in $$ZONES; do \
		echo "Trying ZONE=$$zone..."; \
		if $(MAKE) create-instance ZONE=$$zone; then \
			echo "ZONE=$$zone worked!"; \
			echo "export ZONE=$$zone" > .zone; \
			$(MAKE) set-zone; \
			echo "NEXT: make setup-instance"; \
			exit 0; \
		fi; \
	done; \
	echo "No ZONE value worked."; \
	exit 1

set-zone:: # set zone
	gcloud config set compute/region ${REGION}
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
DISK_OPTIONS = \
	auto-delete=yes \
	boot=yes \
	device-name=${INSTANCE} \
	image=projects/ml-images/global/images/c0-deeplearning-common-gpu-v20240605-debian-11-py310 \
	mode=rw \
	size=${BOOT_DISK_SIZE} \
	type=${BOOT_DISK_TYPE}
endif


create-instance:: # create a remote instance
ifeq (${COMPUTE}, gpu)
	gcloud compute instances create ${INSTANCE} \
		--project=${PROJECT} \
		--zone=${ZONE} \
		--machine-type=g2-standard-16 \
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


setup-instance:: # set up instance after creation
	make update-config
	sleep 10
# first time, just ssh in to see if it works
# remember to say yes to nvidia
	${REMOTE}
# now forward the ports
	make forward-ports
	scp dot-files/.tmux.conf @${INSTANCE}:
	${REMOTE} "mkdir scripts"
	scp scripts/*py @${INSTANCE}:scripts/


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
	make continue-instance

continue-instance:
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
MODEL=phi3.5
MODEL=mistral-small
#MODEL=command-r

stop-ollama: # stop local ollama
	sudo killall Ollama

install-ollama::
	${REMOTE} "mkdir -p ollama"
	${REMOTE} "curl https://ollama.ai/install.sh > ollama/install.sh"
	${REMOTE} "sh ollama/install.sh"
	${REMOTE} -t -t "ollama pull ${MODEL}"
	${REMOTE} -t -t "ollama run ${MODEL} Say hi and nothing else"

populate-ollama::
	${REMOTE} -t -t "ollama pull"

start-ollama:
	${REMOTE} -t -t "ollama list"

load-ollama-model:
	${REMOTE} -t -t "ollama run ${MODEL}"


#############################################################################
# Fooocus
#############################################################################

FOOOCUS=Fooocus
CONNECTED_DIRS = checkpoints loras controlnet

install-fooocus::
	${REMOTE} "git clone https://github.com/lllyasviel/Fooocus.git"
	${REMOTE} "cd ${FOOOCUS}; ${REMOTE_PYTHON} -m venv venv"
	${REMOTE} "cd ${FOOOCUS}; PYTHONPATH=. ./venv/bin/pip install -r requirements_versions.txt"

# This installs fooocus weights first time around
run-fooocus::
	${REMOTE} -t "cd ${FOOOCUS}; tmux new-session -s fooocus '. ./venv/bin/activate ; python entry_with_update.py ; bash'"

attach-fooocus::
	${REMOTE} -t tmux attach -t fooocus

capture-fooocus::
	${REMOTE} tmux capture-pane -t fooocus -p

kill-fooocus::
	${REMOTE} tmux kill-session -t fooocus

connect-fooocus:: # connect the storage command
	@for variant in $(CONNECTED_DIRS); do \
		${REMOTE} "echo '${GOOGLE_STORAGE}/fooocus/$${variant}' | tee './${FOOOCUS}/models/$${variant}/.gstorage'"; \
	done

restore-fooocus::
	${REMOTE} "cd ${FOOOCUS} ; gsutil -m rsync -c ${GOOGLE_STORAGE}/fooocus/checkpoints models/checkpoints"
	${REMOTE} "cd ${FOOOCUS} ; gsutil -m rsync -c ${GOOGLE_STORAGE}/fooocus/loras models/loras"
	${REMOTE} "cd ${FOOOCUS} ; gsutil -m rsync -c ${GOOGLE_STORAGE}/fooocus/loras models/controlnet"

preserve-fooocus::
	${REMOTE} "cd ${FOOOCUS}/models/checkpoints ; gsutil rsync -c . ${GOOGLE_STORAGE}/fooocus/checkpoints"
	${REMOTE} "cd ${FOOOCUS}/models/loras       ; gsutil rsync -c . ${GOOGLE_STORAGE}/fooocus/loras"
	${REMOTE} "cd ${FOOOCUS}/models/controlnet  ; gsutil rsync -c . ${GOOGLE_STORAGE}/fooocus/controlnet"


#############################################################################                                                           
# Kohya                                                                                                                                 
#############################################################################                                                           

KOHYA=kohya_ss

install-kohya::
	${REMOTE} "git clone https://github.com/bmaltais/kohya_ss.git"
	${REMOTE} '${SET_CONDA_BIN} ; cd ${KOHYA}; chmod +x ./setup.sh ; ./setup.sh'
	${REMOTE} -t '${SET_CONDA_BIN} ; cd ${KOHYA}; . ./venv/bin/activate ; accelerate config default'

run-kohya::
	${REMOTE} -t "cd ${KOHYA}; tmux new-session -s kohya 'chmod +x ./gui.sh ; ./gui.sh'"

attach-kohya::
	${REMOTE} -t tmux attach -t kohya

capture-kohya::
	${REMOTE} tmux capture-pane -t kohya -p

kill-kohya::
	${REMOTE} tmux kill-session -t kohya

upload-bucket::
	scp bucket @${INSTANCE}:bucket
