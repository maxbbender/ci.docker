#!/bin/bash
#
# (C) Copyright IBM Corporation 2016, 2017
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -o pipefail

function usage() {
	echo
	echo "Usage: $0 [-h] [-i <j|t|b>] [-l] [-n] [-v <8|9>] [-s source_repo] [-t <ibmcom|ppc64le|s390x>]"
	echo " h = help. "
	echo " i = Images to be pushed, j = java only, t = tools only, default = both. "
	echo " l = use local source. "
	echo " n = no push to remote. "
	echo " s = source repo, default = j9. "
	echo " t = target repo, default = ibmcom. "
	echo " v = version of binaries to push. "
	echo
	exit 1
}

dver=`docker version 2>/dev/null`
if [ $? != 0 ]; then
	echo "ERROR: Docker command is running in unprivileged mode."
	echo "       Run Docker with sudo privileges or make sure the userid is part of the docker group."
	exit 1
fi

machine=`uname -m`
push_repo="ibmjava"
nopush=0

unset jvar
tools="maven"
image="b"

# Setup defaults for source and target repos based on the current machine arch.
case $machine in
x86_64)
	source_repo="j9"
	tprefix="ibmcom"
	remote=0
	;;
s390x)
	source_repo="s390x/j9"
	tprefix="s390x"
	# No remote repos to pull from for s390x
	remote=0
	;;
ppc64le)
	source_repo="ppc64le/j9"
	tprefix="ppc64le"
	# No remote repos to pull from for ppc64le
	remote=0
	;;
default)
	echo "Unsupported arch:$machine. Exiting"
	exit
	;;
esac

while getopts hi:lns:t:v: opts
do
	case $opts in
	i)
		# which images to push.
		image="$OPTARG"
		[[ $image == "j" || $image == "t"  || $image == "b" ]] || usage
		;;
	l)
		# Use local repo instead of pulling from remote source.
		remote=0
		;;
	n)
		# Do not push to remote.
		nopush=1
		;;
	s)
		# Use provided source repo to pull from.
		source_repo="$OPTARG"
		;;
	t)
		# Push to given target PREFIX
		tprefix="$OPTARG"
		[[ $tprefix == "ibmcom" || $tprefix == "ppc64le" || $tprefix == "s390x" ]] || usage
		;;
	v)
		# Update only provided version
		jver="$OPTARG"
		((jver == 8 || jver == 9)) || usage
		;;
	*)
		usage
	esac
done
shift $(($OPTIND-1))

logfile=sync-$tprefix-$$.log
target_repo=$tprefix/$push_repo

function log {
	echo -e $@ 2>&1 | tee -a $logfile
}

log
if [ $remote -eq 1 ]; then
	log "####[I]: Push docker images from $source_repo to $target_repo"
else
	log "####[I]: Push docker images from local to $target_repo"
fi
log

function checkFail() {
	if [ $? != 0 ]; then
		log $@
		exit 1
	fi
}

function retag() {
	stag=$1
	ttag=$2

	# Check if the target images are existing locally and if so, remove them.
	image=`docker images | grep "$target_repo" | awk '{ print $2 }' | grep "^$ttag$"`
	if [ "$image" != "" ]; then
		log -n "####[I]: [$target_repo:$ttag]: Deleting old image with tag [$ttag]..."
		docker rmi $target_repo:$ttag >> $logfile 2>&1
		log "done"
	fi
	# Create the target image locally with the appropriate tag from the source.
	log -n "####[I]: [$source_repo:$stag]: Tagging image as [$target_repo:$ttag]..."
	#docker tag $source_repo:$stag $target_repo:$ttag >> $logfile 2>&1
	log "done"
}

function push_target() {
	ttag=$1

	if [ $nopush -eq 0 ]; then
		log
		# Push the target images to the remote
		log "####[I]: [$target_repo:$ttag]: Pushing image to hub.docker..."
		#docker push $target_repo:$ttag >> $logfile 2>&1
		checkFail "####[E]: [$target_repo:$ttag]: Image push failed, check the target repository provided.\n" \
				  "####[E]: Are you logged-in,  does your userid have push authorization?"
		log "####[I]: [$target_repo:$ttag]: Image pushed successfully."
		log
	fi
}

function get_source_image() {
	repo=$1
	stag=$2

	# If source is remote, pull images from remote, else check if image is available locally.
	if [ $remote -eq 1 ]; then
		log -n "####[I]: [$repo:$stag]: Pulling image..."
		#docker pull $repo:$stag >> $logfile 2>&1
		checkFail "\n####[E]: [$repo:$stag]: Pulling image failed, exiting..."
		log "done"
	else
		log -n "####[I]: [$repo:$stag]: Checking for image locally..."
		image=`docker images | grep "$repo" | awk '{ print $2 }' | grep "^$stag$"`
		if [ "$image" == "" ]; then
			log "\n####[E]: [$repo:$stag]: Image not found locally, exiting..."
			#exit 1
		fi
		log "found"
	fi
}

function update_target() {
	stag=$1
	ttag=$2
	
	# Download the source image with the given tag locally. 
	get_source_image $source_repo $stag

	retag $stag $ttag

	# Push it to the remote repo.
	push_target $ttag
}

function parse_array() {
	for i in `seq 0 $(( ${#tagsarray[@]} - 1 ))`
	do
		declare -a imagearray=( ${tagsarray[$i]} )
		update_target ${imagearray[0]} ${imagearray[0]}
		for j in `seq 1 $(( ${#imagearray[@]} - 1 ))`
		do
			update_target ${imagearray[0]} ${imagearray[$j]}
		done
	done
}

function read_file() {
	file=$1

	if [ ! -z "$jver" ]; then
		readarray tagsarray <<< "$(cat $file | grep "^$jver")"
	else
		readarray tagsarray < $file
	fi
	parse_array
}

# Read from tags file
if [ $image == "j" ]; then
	read_file java_tags.txt
elif [ $image == "t" ]; then
	read_file tool_tags.txt
else
	read_file java_tags.txt
	read_file tool_tags.txt
fi

log
log "See $logfile for more details"
