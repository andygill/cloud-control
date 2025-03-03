export COMPUTE=gpu
export ID=1
export INSTANCE=instance-${ID}-${COMPUTE}
export BOOT_DISK_SIZE=200
export BOOT_DISK_TYPE=pd-balanced

# comment this out to build from scratch
export BOOT_SNAPSHOT=snapshot-${COMPUTE}-2
export SAVE_SNAPSHOT=snapshot-${COMPUTE}-3

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

# use \"Hello World\" to pass a string with spaces
PYTHON_REMOTE = ${REMOTE} -t ${REMOTE_PYTHON} scripts/remote.py


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

machine-types::
	gcloud compute machine-types list  --filter="zone:(us-*) AND name:(g2-standard-*)" | tee machine-types.txt

list-snapshots::
	gcloud compute snapshots list

create-snapshot::
	gcloud compute snapshots create ${SAVE_SNAPSHOT} \
	--project=${PROJECT} \
	--source-disk=${INSTANCE} \
	--source-disk-zone=${ZONE} \
	--storage-location=${REGION} \

delete-snapshot:: # usage make delete-snapshot SNAPSHOT=...
	echo gcloud compute snapshots delete "[snapshot]"


find-zone:: machine-types.txt
	@echo "Trying to find a working g2-standard-16 in US ZONE"
	@ZONES=$$(cat machine-types.txt | grep us- | grep g2-standard-16 | awk '{print $$2}' | sort -u | tr '\n' ' '); \
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

ifdef BOOT_SNAPSHOT
DISK_SRC := source-snapshot=https://www.googleapis.com/compute/v1/projects/${PROJECT}/global/snapshots/${BOOT_SNAPSHOT}
else
DISK_SRC := image=projects/ml-images/global/images/c0-deeplearning-common-gpu-v20240922-debian-11-py310
endif

DISK_OPTIONS = \
	auto-delete=yes \
	boot=yes \
	device-name=${INSTANCE} \
	${DISK_SRC} \
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
	@echo waiting for 10s or user input.
	-read -t 10
	echo Done
# first time, just ssh in to see if it works
# remember to say yes to nvidia
	${REMOTE}
# Copy the key utilties
	make copy-scripts
# now forward the ports
	make forward-ports

copy-scripts::
	scp dot-files/.tmux.conf @${INSTANCE}:
	${REMOTE} "mkdir -p scripts"
	scp scripts/*py @${INSTANCE}:scripts/
	${REMOTE} "mkdir -p patches"
	scp patches/*patch @${INSTANCE}:patches/

# can compare local and remote using
diff:
	ssh ${REMOTE_USER}@${INSTANCE} "cat ${FILE}" | diff - ${FILE}

####################################################################################
# Port forwarding
####################################################################################

PORT_SESSION=background-ports
OLLAMA_PORT=11435:localhost:11434 

forward-ports::
	tmux new-session -d -s ${PORT_SESSION} \
		"gcloud compute ssh ${INSTANCE} -- -NL $(OLLAMA_PORT) $(foreach item,$(FORWARD_PORTS), -NL $(item):localhost:$(item))"
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
	echo consider: make delete-instance, snap-and-delete-instance, list-snapshots, or make create-snapshot
	echo snapping to ${SAVE_SNAPSHOT}

snap-and-delete-instance::
	make create-snapshot
	make list-snapshots
	make delete-instance

delete-instance:
	gcloud compute instances delete ${INSTANCE}

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

stop-local-ollama: # stop local ollama
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

# serve-ollama:
# 	${REMOTE} -t "tmux new-session -s ollama 'OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 ollama serve; bash'"
# #	${REMOTE} -t "tmux new-session -s ollama 'ollama serve; bash'"



stop-ollama:
	${REMOTE} -t "sudo systemctl stop ollama"

load-ollama-model:
	${REMOTE} -t -t "ollama run ${MODEL}"

attach-fooocus::
	${REMOTE} -t tmux attach -t fooocus

capture-fooocus::
	${REMOTE} tmux capture-pane -t fooocus -p

kill-fooocus::
	${REMOTE} tmux kill-session -t fooocus


#############################################################################
# Fooocus
#############################################################################

FOOOCUS=Fooocus
CONNECTED_DIRS = checkpoints loras controlnet

install-fooocus::
	${REMOTE} "git clone https://github.com/lllyasviel/Fooocus.git"
	${REMOTE} "cd ${FOOOCUS}; ${REMOTE_PYTHON} -m venv venv"
	${REMOTE} "cd ${FOOOCUS}; PYTHONPATH=. ./venv/bin/pip install -r requirements_versions.txt"


install-fooocus-api::
	${REMOTE} "git clone https://github.com/mrhan1993/Fooocus-API.git"
	${REMOTE} "cd ${FOOOCUS}-API; ${REMOTE_PYTHON} -m venv venv"
# 	(does not build out of the box)
	${REMOTE} "cd ${FOOOCUS}-API; PYTHONPATH=. ./venv/bin/pip install colorlog packaging"
# 	(assuming that foocus has been built)
	${REMOTE} "cd ${FOOOCUS}-API; mv config.txt config.save.txt ; mv ../${FOOOCUS}/config.txt ."


# This installs fooocus weights first time around
run-fooocus::
	${REMOTE} -t "cd ${FOOOCUS}; tmux new-session -s fooocus '. ./venv/bin/activate ; python entry_with_update.py ; bash'"

run-fooocus-api::
	${REMOTE} -t "cd ${FOOOCUS}-API; tmux new-session -s fooocus-api '. ./venv/bin/activate ; python main.py ; bash'"


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

#############################################################################
# Stable Diffusion WebUI Forge
#############################################################################

FORGE=forge

install-forge::
	${REMOTE} "git clone https://github.com/lllyasviel/stable-diffusion-webui-forge.git ${FORGE}"
	${REMOTE} "cd ${FORGE}; ${REMOTE_PYTHON} -m venv venv"
	${REMOTE} "cd ${FORGE}; patch webui-user.sh ~/patches/webui-user.patch"
	${REMOTE} "cd ${FORGE}; . ./venv/bin/activate ; pip install -r requirements_versions.txt"

connect-forge::
	${REMOTE} "mkdir -p './${FORGE}/models/Stable-diffusion/flux'"
	${REMOTE} "mkdir -p './${FORGE}/models/Stable-diffusion/sdxl'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/checkpoints' | tee './${FORGE}/models/Stable-diffusion/.gstorage'"
	${REMOTE} "mkdir -p './${FORGE}/models/Lora/flux'"
	${REMOTE} "mkdir -p './${FORGE}/models/Lora/sdxl'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/loras' | tee './${FORGE}/models/Lora/.gstorage'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/vae' | tee './${FORGE}/models/VAE/.gstorage'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/text_encoder' | tee './${FORGE}/models/text_encoder/.gstorage'"

populate-forge::
	${REMOTE} "cd ${FORGE}/models/Stable-diffusion/flux; ${REMOTE_PYTHON} ~/scripts/storage.py pull flux1-dev-fp8.safetensors"
	${REMOTE} "cd ${FORGE}/models/VAE; ${REMOTE_PYTHON} ~/scripts/storage.py pull ae.safetensors"
	${REMOTE} "cd ${FORGE}/models/text_encoder; ${REMOTE_PYTHON} ~/scripts/storage.py pull clip_l.safetensors t5xxl_fp8_e4m3fn.safetensors"

# This installs it first time around
run-forge::
	# do not activate because webui.sh does this for us
	${REMOTE} -t "cd ${FORGE}; tmux new-session -s forge '. ; ./webui.sh ; bash'"


attach-forge::
	${REMOTE} -t tmux attach -t forge

capture-forge::
	${REMOTE} tmux capture-pane -t forge -p

# This kills the tmux shell that contains 
kill-forge::
	${REMOTE} tmux kill-session -t forge

#############################################################################
# Flux Gym
#############################################################################

FLUXGYM=fluxgym

install-fluxgym::
	${REMOTE} "git clone https://github.com/cocktailpeanut/fluxgym.git ${FLUXGYM}"
	${REMOTE} "cd ${FLUXGYM}; git clone -b sd3 https://github.com/kohya-ss/sd-scripts"
	${REMOTE} "cd ${FLUXGYM}; ${REMOTE_PYTHON} -m venv venv"
	${REMOTE} "cd ${FLUXGYM}; . ./venv/bin/activate ; cd sd-scripts ; pip install -r requirements.txt"
	${REMOTE} "cd ${FLUXGYM}; . ./venv/bin/activate ; pip install -r requirements.txt"
	${REMOTE} "cd ${FLUXGYM}; . ./venv/bin/activate ; pip install --pre torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121"


# This installs it first time around
run-fluxgym::
	${REMOTE} -t "cd ${FLUXGYM}; tmux new-session -s ${FLUXGYM} '. ./venv/bin/activate ; python app.py ; bash'"


attach-fluxgym::
	${REMOTE} -t tmux attach -t ${FLUXGYM}

capture-fluxgym::
	${REMOTE} tmux capture-pane -t  ${FLUXGYM} -p

# This kills the tmux shell that contains 
kill-fluxgym::
	${REMOTE} tmux kill-session -t  ${FLUXGYM}

#############################################################################
# ComfyUI
#############################################################################

COMFY_UI=ComfyUI

install-comfyui:: 
	${REMOTE} "git clone https://github.com/comfyanonymous/ComfyUI.git"
	${REMOTE} "cd ${COMFY_UI}/custom_nodes ; git clone https://github.com/ltdrdata/ComfyUI-Manager.git"
	${REMOTE} "cd ${COMFY_UI}/custom_nodes ; git clone https://github.com/webfiltered/DebugNode-ComfyUI.git"
	# change to 
	${PYTHON_REMOTE} --pwd ${COMFY_UI} "conda init"
	#	${REMOTE} "cd ${COMFY_UI}; ${REMOTE_PYTHON} -m venv venv"

	# This was something about sharing models
	# ${REMOTE} "cd ${COMFY_UI} ; sed 's/path\/to\//..\//' extra_model_paths.yaml.example > extra_model_paths.yaml"



run-comfyui::
	${PYTHON_REMOTE} --pwd ${COMFY_UI} "conda activate"
	${PYTHON_REMOTE} --pwd ${COMFY_UI} --tmux ${COMFY_UI} "python main.py"

connect-comfyui:
	${REMOTE} "mkdir -p './${COMFY_UI}/models/checkpoints/flux'"
	${REMOTE} "mkdir -p './${COMFY_UI}/models/checkpoints/sdxl'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/checkpoints' | tee './${COMFY_UI}/models/checkpoints/.gstorage'"
	${REMOTE} "mkdir -p './${COMFY_UI}/models/loras/flux'"
	${REMOTE} "mkdir -p './${COMFY_UI}/models/loras/sdxl'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/loras' | tee './${COMFY_UI}/models/loras/.gstorage'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/vae' | tee './${COMFY_UI}/models/vae/.gstorage'"
	${REMOTE} "echo '${GOOGLE_STORAGE}/models/text_encoder' | tee './${COMFY_UI}/models/text_encoders/.gstorage'"
	

attach-comfyui::
	${REMOTE} -t tmux attach -t ${COMFY_UI}

capture-comfyui::
	${REMOTE} tmux capture-pane -t  ${COMFY_UI} -p

# This kills the tmux shell that contains 
kill-comfyui::
	${REMOTE} tmux kill-session -t  ${COMFY_UI}
