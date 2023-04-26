#!/usr/bin/env bash

set -ex

cd "$(dirname "${BASH_SOURCE[0]}")"

BUILDER=
PUSH=
LOAD=
LATEST=
IMAGE_NAME="nwaku"

for i in `seq 1 $#`;do
    case $1 in
        "--builder")
            shift
            BUILDER="--builder ${1}"
            shift
            ;;
        "--push")
            shift
            PUSH="--push"
            ;;
        "--load")
            shift
            LOAD="--load"
            ;;
        "--registry")
            shift
            REGISTRY="${1}/"
            shift
            ;;
        "--repository")
            shift
            REPOSITORY="${1}/"
            shift
            ;; 
        "--latest")
            shift
            LATEST="1"
            ;; 
        *)
            break
            ;;
    esac
done

IMAGE_NAME=${REGISTRY}${REPOSITORY}${IMAGE_NAME}

ARCHS=$(ls Dockerfile.* | sed 's/.*\.//')

ARCH="${@:-amd64}"



if [[ "${ARCH}" == "all" ]]; then
    echo "Building all images: $( echo ${ARCHS} | tr '\n' ' ')"
    ARCH=${ARCHS}
fi

TAG="nwaku-base-$(date --utc +"%Y%m%d%H%M%S")"

for arch in $(echo ${ARCH}); do
    DOCKER_BUILDKIT=1 \
        docker build\
            ${BUILDER}\
            ${PUSH}\
            ${LOAD}\
            -t ${IMAGE_NAME}:${TAG}_${arch}\
            --build-arg USER_ID=$(id -u)\
            --build-arg GROUP_ID=$(id -g)\
            -f Dockerfile.${arch}\
            .

    if [[ -n "${LATEST}" ]]; then
        docker tag\
            ${IMAGE_NAME}:${TAG}_${arch}\
            ${IMAGE_NAME}:latest_${arch}
    fi
done
