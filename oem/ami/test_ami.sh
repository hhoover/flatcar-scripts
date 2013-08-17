#!/bin/bash
#
# This expects to run on an EC2 instance.
#
# mad props to Eric Hammond for the initial script
#  https://github.com/alestic/alestic-hardy-ebs/blob/master/bin/alestic-hardy-ebs-build-ami

# This script will launch three ec2 nodes with shared user-data, and then 
# then test of the cluster is bootstrapped

# Set pipefail along with -e in hopes that we catch more errors
set -e -o pipefail

USAGE="Usage: $0 -a ami-id
    -a ami-id   ID of the AMI to be tests (required)
    -K KEY      Path to Amazon API private key.
    -C CERT     Path to Amazon API key certificate.
    -h          this ;-)
    -v          Verbose, see all the things!

This script must be run from an ec2 host with the ec2 tools installed.
"

while getopts "a:K:C:hv" OPTION
do
    case $OPTION in
        a) AMI="$OPTARG";;
        K) export EC2_PRIVATE_KEY="$OPTARG";;
        C) export EC2_CERT="$OPTARG";;
        h) echo "$USAGE"; exit;;
        v) set -x;;
        *) exit 1;;
    esac
done

if [[ $(id -u) -eq 0 ]]; then
    echo "$0: This command should not be ran run as root!" >&2
    exit 1
fi

if [ -z "$AMI" ]; then
    echo "AMI required" >&2
    echo "$USAGE" >&2
    exit 1
fi

# check to make sure this is a valid image
if ! ec2-describe-images -F image-id="$AMI" | grep -q "$AMI"; then
    echo "Unknown image: $AMI" >&2
    exit 1
fi

key_name="autotest-`date +%s`"
key_file="/tmp/$key_name"
ec2-create-keypair $key_name | grep -v KEYPAIR > $key_file
chmod 600 $key_file

sg_name=$key_name
sg=$(ec2-create-group $sg_name --description "$sg_name" | cut -f2)
ec2-authorize "$sg_name" -P tcp -p 4001 > /dev/null
ec2-authorize "$sg_name" -P tcp -p 7001 > /dev/null
ec2-authorize "$sg_name" -P tcp -p 22 > /dev/null

# might be needed later for multi-zone tests
zoneurl=http://instance-data/latest/meta-data/placement/availability-zone
zone=$(curl --fail -s $zoneurl)
region=$(echo $zone | sed 's/.$//')

token=$(dd if=/dev/urandom bs=8 count=1 2> /dev/null| sha1sum|cut -d' ' -f1)

instances=$(ec2-run-instances \
    --user-data "$token" \
    --instance-type "t1.micro" \
    --instance-count 3 \
    --group "$sg_name" \
    --key "$key_name" $AMI | \
       grep INSTANCE | cut -f2)

# little hack to create a describe instances command that only 
# pulls data for these instances
ec2_cmd=$(echo $instances | sed 's/ / --filter instance-id=/g')
ec2_cmd="ec2-describe-instances --filter instance-id=$ec2_cmd"

while $ec2_cmd | grep INSTANCE | grep -q pending
  do sleep 10; done

declare -a ips=($($ec2_cmd | grep INSTANCE | cut -f4))

# sleep until all the sockets we need come up
for host in ${ips[@]}; do
    timeout 30 perl -MIO::Socket::INET -e "
        until(new IO::Socket::INET('$host:22')){sleep 1}"
    timeout 30 perl -MIO::Socket::INET -e "
        until(new IO::Socket::INET('$host:4001')){sleep 1}"
    timeout 30 perl -MIO::Socket::INET -e "
        until(new IO::Socket::INET('$host:7001')){sleep 1}"
done

test_key="v1/keys/test"
# XXX: the sleeps *should never* be required, this is a bug in etcd
sleep 1
curl --fail -s -L "${ips[0]}:4001/$test_key" -d value="$token" > /dev/null
sleep 1
for host in ${ips[@]}; do
    if ! curl --fail -s -L "${host}:4001/$test_key" | grep -q $token; then
        echo "etcd bootstrap appears to have failed for $host" >&2
	exit 1
    fi
done

ec2-terminate-instances $instances > /dev/null
while ! $ec2_cmd | grep INSTANCE | grep -q terminated
  do sleep 10; done

ec2-delete-group $sg_name > /dev/null
ec2-delete-keypair $key_name > /dev/null
rm $key_file
