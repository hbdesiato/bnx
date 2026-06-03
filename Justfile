PROJECT_NAME:=`basename "$PWD"`
PROJECT_REPO:="localhost:5000"
THIS_IMAGE:=PROJECT_REPO+"/"+PROJECT_NAME+"-unsealed"
SEALED_IMAGE:=PROJECT_REPO+"/"+PROJECT_NAME
BASE_IMAGE:="ghcr.io/ublue-os/bluefin:latest"

build $BUILD_ARGS="" $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    podman build ${BUILD_ARGS} --build-arg BASE_IMAGE="${BASE_IMAGE}" -t "${THIS_IMAGE}" .

push $THIS_IMAGE=THIS_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    DIGEST="${THIS_IMAGE##*/}.digest"
    podman push --sign-by-sigstore-private-key keys/sigstore.private --sign-passphrase-file keys/sigstore.passphrase \
        --digestfile="${DIGEST}" "${THIS_IMAGE}"
    git add "${DIGEST}"
    git commit -m "${THIS_IMAGE} pushed"

seal $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    if [ -e fedora-atomic-desktops-sealed ]; then
        git -C fedora-atomic-desktops-sealed fetch
        git -C fedora-atomic-desktops-sealed reset --hard
    else
        git clone https://github.com/travier/fedora-atomic-desktops-sealed
    fi
    sed -i '/# Changes for development go here/a\exit 0' fedora-atomic-desktops-sealed/scripts/prepare-rootfs.sh
    rm -r fedora-atomic-desktops-sealed/keys
    ln -s ../keys fedora-atomic-desktops-sealed/keys
    # DIGEST="$(cat "${THIS_IMAGE##*/}.digest" | tr -d '\n')"
    just -ffedora-atomic-desktops-sealed/justfile dest_registry=localhost sign-systemd-boot
    just -ffedora-atomic-desktops-sealed/justfile dest_registry=localhost build-tools
    just -ffedora-atomic-desktops-sealed/justfile \
        variant_repos="( [bootc]=${THIS_IMAGE} )" \
        variant_versions="( [bootc]=latest )" \
        dest_registry=localhost \
        build bootc
    podman tag localhost/bootc:latest "${SEALED_IMAGE}"

build-seal-push $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    just build --no-cache "${THIS_IMAGE}" "${BASE_IMAGE}"
    just push "${THIS_IMAGE}"
    just seal "${SEALED_IMAGE}" "${THIS_IMAGE}"
    just push "${SEALED_IMAGE}"

update $SEALED_IMAGE=SEALED_IMAGE $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    if just pkgs-check "${THIS_IMAGE}" "${BASE_IMAGE}" && just base-check "${THIS_IMAGE}" "${BASE_IMAGE}"
    then exit 0
    fi
    just build-seal-push "${SEALED_IMAGE}" "${THIS_IMAGE}" "${BASE_IMAGE}"

pkgs-list $IMAGE=BASE_IMAGE:
    podman run --rm "${IMAGE}" rpm -q --qf="%{NAME}\n" -a

pkgs-diff $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    printf '%s\n%s\n' "$(just pkgs-list "${THIS_IMAGE}")" "$(just pkgs-list "${BASE_IMAGE}")" | sort | uniq -u | tr '\n' ' '

pkgs-check $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    podman run --rm "${THIS_IMAGE}" dnf check-upgrade $(just pkgs-diff "${THIS_IMAGE}" "${BASE_IMAGE}" | tr '\n' ' ')

base-check $THIS_IMAGE=THIS_IMAGE $BASE_IMAGE=BASE_IMAGE:
    #!/usr/bin/env bash
    set -euxo pipefail
    digest1="$(podman image inspect --format '{{{{index .Annotations "org.opencontainers.image.base.digest"}}' "${THIS_IMAGE}")"
    podman pull "${BASE_IMAGE}"
    digest2="$(podman image ls --format '{{{{.Digest}}' "${BASE_IMAGE}")"
    [ "${digest1}" = "${digest2}" ]

generate-keys $PROJECT_NAME=PROJECT_NAME:
    #!/usr/bin/env bash
    set -euxo pipefail
    [ ! -e keys ] || exit 0
    mkdir -p keys/db
    umask 0077
    <<<"" cat >"keys/sigstore.passphrase"
    skopeo generate-sigstore-key --passphrase-file "keys/sigstore.passphrase" --output-prefix "keys/sigstore"
    openssl genpkey -algorithm rsa -pkeyopt rsa_keygen_bits:4096 -out keys/db/db.key
    openssl x509 -new -key keys/db/db.key -set_subject "/CN=${PROJECT_NAME} secure boot/" -out keys/db/db.pem
    openssl x509 -outform DER -in keys/db/db.pem -out keys/db/db.cer
    uuidgen > keys/GUID

generate-config $PROJECT_REPO=PROJECT_REPO:
    #!/usr/bin/env bash
    set -euxo pipefail
    CONFIG="${HOME}/.config"
    mkdir -p "${CONFIG}/containers/registries.d"
    cat >"${CONFIG}/containers/registries.d/sigstore.yaml" <<EOC
    docker:
        ${PROJECT_REPO}:
            use-sigstore-attachments: true
        ghcr.io/ublue-os:
            use-sigstore-attachments: true
    EOC
    cat "${CONFIG}/containers/registries.d/sigstore.yaml"
    jq >"${CONFIG}/containers/policy.json" <<EOC
    {
        "default": [
            {
                "type": "insecureAcceptAnything"
            }
        ],
        "transports": {
            "docker": {
                "${PROJECT_REPO}": [
                    {
                        "type": "sigstoreSigned",
                        "keyPath": "$(realpath keys/sigstore.pub)",
                        "signedIdentity": {
                            "type": "matchRepository"
                        }
                    }
                ],
                "ghcr.io/ublue-os": [
                    {
                        "type": "sigstoreSigned",
                        "keyPath": "$(realpath ublue-os.pub)",
                        "signedIdentity": {
                            "type": "matchRepository"
                        }
                    }
                ]
            }
        }
    }
    EOC
    cat "${CONFIG}/containers/policy.json"
gh-setup $PROJECT_REPO=PROJECT_REPO:
    #!/usr/bin/env bash
    set -euxo pipefail
    git config --global user.name "github-actions[bot]"
    git config --global user.email "github-actions[bot]@users.noreply.github.com"
    just generate-config "${PROJECT_REPO}"
    umask 0077
    <<<"${SIGSTORE_PRIVATE}" cat >"keys/sigstore.private"
    <<<"" cat >"keys/sigstore.passphrase"
    <<<"${DB_KEY}" cat >keys/db/db.key
