#!/bin/bash

PRE_IFS=$IFS

# -------------------------- Logging --------------------------
log() {
    echo -e "\n[INFO] $1"
}

error_exit() {
    echo "[ERROR] $1"
    exit 1
}

# -------------------------- Extract local_repo.tar.gz --------------------------
extract_local_repo_files() {
    declare -gA local_repo_kvarray
    local_repo_tar=$(find / -name "local_repo.tar.gz" 2> /dev/null | head -n 1)

    if [[ -z $local_repo_tar ]]; then
        error_exit "local_repo.tar.gz 파일을 찾을 수 없습니다."
    fi

    log "local_repo.tar.gz 압축 해제 중..."
    extracted_files=($(tar -xvzf "$local_repo_tar"))

    for value in "${extracted_files[@]}"; do
        key=$(echo "$value" | cut -d '_' -f 1)
        local_repo_kvarray["$key"]="$(realpath "$value")"
    done
}

# -------------------------- OS Version --------------------------
get_os_version() {
    eval "$(bash /util/file_to_map.sh '/etc/*release')" || error_exit "버전 정보 로드 실패"
    version_id=$(printf "%.0f" "${map["VERSION_ID"]}")
    echo $version_id
}

select_repo_file() {
    local version_id="$1"
    if [[ $version_id -le 7 ]]; then
        echo "${local_repo_kvarray["centOS7"]}"
    else
        echo "${local_repo_kvarray["centOS8"]}"
    fi
}

# -------------------------- ISO 장치 선택 --------------------------
select_iso_device() {
    declare -ga device_list
    declare -gA device_kvarr

    log "iso9660 타입 CD-ROM 장치를 검색합니다..."
    mount_point="/mnt"
    index=0

    mapfile -t found_devices < <(blkid | grep 'iso9660' | cut -d: -f1)

    if [[ ${#found_devices[@]} -eq 0 ]]; then
        echo "[ERROR] iso9660 타입 장치를 찾지 못했습니다."
        exit 1
    fi

    for dev in "${found_devices[@]}"; do
        echo "[DEBUG] 장치 마운트 시도: $dev"
        umount "$mount_point" &>/dev/null
       
        mount "$dev" "$mount_point" &>/dev/null
        ret=$?
        
        echo "[DEBUG] mount 결과 코드: $ret"
        echo "[DEBUG] $mount_point 디렉토리 내용:"
        ls -al "$mount_point"

        if [[ $ret -eq 0 ]]; then
            if [[ -f "$mount_point/.treeinfo" ]]; then
                echo "[DEBUG] .treeinfo 있음:"
                cat "$mount_point/.treeinfo" | grep name || echo "[DEBUG] name 항목 없음"

                name=$(sed -n "/^\[general\]/,/^\[/p" "$mount_point/.treeinfo" \
                      | sed "1d;/^\[/q" | grep name | cut -d "=" -f 2 | xargs)

                echo "[DEBUG] name 파싱 결과: '$name'"

                device_list[$index]="$dev"
                device_kvarr["$dev"]="$name"
                echo "[DEBUG] -> 감지됨: $dev ($name)"
                index=$((index + 1))
            else
                echo "[DEBUG] .treeinfo 없음"
            fi
        else
            echo "[DEBUG] -> 마운트 실패: $dev"
        fi

        umount "$mount_point" &>/dev/null
    done

    if [[ ${#device_list[@]} -eq 0 ]]; then
        echo "[ERROR] .treeinfo 파일을 가진 ISO 장치를 찾을 수 없습니다."
        exit 1
    fi

    echo ""
    echo "-------- 사용할 ISO 장치를 선택하세요 --------"
    echo "Index    Device       LABEL"
    echo "=================================="

    for i in "${!device_list[@]}"; do
        dev="${device_list[$i]}"
        label="${device_kvarr[$dev]}"
        echo "$i        $dev      $label"
    done

    echo ""
    while true; do
        read -p "선택할 Index 입력: " sel
        if [[ "$sel" =~ ^[0-9]+$ && "$sel" -ge 0 && "$sel" -lt ${#device_list[@]} ]]; then
            selected_dev="${device_list[$sel]}"
            break
        else
            echo "[WARN] 잘못된 입력입니다. 다시 선택하세요."
        fi
    done

    echo "[INFO] 선택된 장치: $selected_dev"
    echo "[DEBUG] 선택된 장치 마운트 시도: $selected_dev → $mount_point"
    umount "$mount_point" &>/dev/null
    mount | grep "$selected_dev" || echo "[DEBUG] 현재 장치는 아직 마운트되지 않음"

    mount "$selected_dev" "$mount_point"
    ret=$?

    if [[ $ret -eq 0 ]]; then
        echo "[DEBUG] 마운트 성공!"
    else
        echo "[ERROR] $selected_dev 마운트 실패 (exit code: $ret)"
        exit 1
    fi

    echo "[INFO] $selected_dev 가 $mount_point 에 마운트되었습니다."
}

# -------------------------- 디렉토리 복사 --------------------------
copy_mounted_files() {
    read -p "------ /mnt에서 복사할 디렉토리 이름을 입력하세요 ------: " dirname
    dirpath="/${dirname}"

    log "$dirpath 생성 및 /mnt 내용 복사"
    mkdir -p "$dirpath"
    rsync -ah --info=progress2 /mnt/ "$dirpath/" || error_exit "복사 실패"
}

# -------------------------- .repo 백업 --------------------------
backup_repo_files() {
    log "/etc/yum.repos.d/ 백업 중..."
    cd /etc/yum.repos.d/
    mkdir -p bak

    shopt -s nullglob
    repo_files=(*.repo)
    if [[ ${#repo_files[@]} -gt 0 ]]; then
        mv "${repo_files[@]}" bak/
    else
        log ".repo 파일이 없습니다."
    fi
    shopt -u nullglob
}

# -------------------------- baseurl 경로 설정 --------------------------
build_baseurl_map() {
    declare -gA baseurl_kvarray
    value_head="file://"
    value_tails=$(find "$1" -name "Packages")

    for value_tail in $value_tails; do
        key=""
        value_tail=$(echo "$value_tail" | sed "s/Packages.*//")
        value="baseurl=${value_head}${value_tail}"

        IFS="/"
        for word in $value_tail; do
            [[ $word == "Packages" ]] && break
            key="$word"
        done
        IFS=$PRE_IFS

        if [[ "$key" != *"AppStream"* && "$key" != *"BaseOS"* ]]; then
            section=$(grep "^\[.*\]$" "$2")
            key=$(echo "$section" | cut -d "-" -f 2 | tr -d "[-]")
        fi

        baseurl_kvarray["$key"]="$value"
    done
}

# -------------------------- local.repo 생성 --------------------------
generate_local_repo() {
    local repo_template="$1"
    local tmp_file="/tmp/tmp_local.repo"
    touch "$tmp_file"
    chmod 777 "$tmp_file"

    local cur_key=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[.*\]$ ]]; then
            cur_key=$(echo "$line" | cut -d "-" -f 2 | tr -d "[-]")
        fi

        if [[ "$line" == *baseurl* ]]; then
            echo "${baseurl_kvarray[$cur_key]}" >> "$tmp_file"
        else
            echo "$line" >> "$tmp_file"
        fi
    done < "$repo_template"

    cp -f "$tmp_file" /etc/yum.repos.d/local.repo
    rm -f "$tmp_file"
}

# -------------------------- 메인 실행 흐름 --------------------------
log "Local Repository 자동 설정 시작"

extract_local_repo_files
version_id=$(get_os_version)
log "현재 OS 버전: $(cat /etc/redhat-release)"

local_repo_file=$(select_repo_file "$version_id")
[[ -z "$local_repo_file" ]] && error_exit "적절한 local_repo 파일을 찾을 수 없습니다."
[[ ! -f "$local_repo_file" ]] && error_exit "$local_repo_file 파일이 존재하지 않습니다."

select_iso_device
copy_mounted_files
backup_repo_files
build_baseurl_map "$dirpath" "$local_repo_file"
generate_local_repo "$local_repo_file"

rm -rv /centOS7_local.repo
rm -rv /centOS8_local.repo

log "yum repolist 실행 결과:"
yum repolist