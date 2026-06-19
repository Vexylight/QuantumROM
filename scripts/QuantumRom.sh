#!/bin/bash

###################################################################################################

REAL_USER=${SUDO_USER:-$USER}

# QT DIR
QT_DIR="$(pwd)"

# Binary
export lpmake="$QT_DIR/bin/lp/lpmake"
export lpunpack="$QT_DIR/bin/lp/lpunpack"
export make_ext4fs="$QT_DIR/bin/ext4/make_ext4fs"
export make_f2fs="$QT_DIR/bin/f2fs-tools/mkfs.f2fs"
export sload_f2fs="$QT_DIR/bin/f2fs-tools/sload.f2fs"
export omc_decoder="$QT_DIR/bin/java/omc-decoder.jar"
export mkfs_erofs="$QT_DIR/bin/erofs-utils/mkfs.erofs"
export extract_erofs="$QT_DIR/bin/erofs-utils/extract.erofs"
export imgextractor_py="$QT_DIR/bin/py_scripts/imgextractor.py"

chmod +x "$lpmake"
chmod +x "$lpunpack"
chmod +x "$make_f2fs"
chmod +x "$sload_f2fs"
chmod +x "$mkfs_erofs"
chmod +x "$make_ext4fs"
chmod +x "$extract_erofs"


CHECK_FILE() {
    if [ ! -f "$1" ]; then
        echo -e "[!] File not found: $1"
        echo -e "- Skipping..."
        return 1
    fi
    return 0
}


REMOVE_LINE() {
    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <TARGET_LINE> <TARGET_FILE>"
        return 1
    fi

    local LINE="$1"
    local FILE="$2"

    echo -e "- Deleting $LINE from $FILE"
    grep -vxF "$LINE" "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
}


GET_PROP() {
    if [ "$#" -ne 3 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION> <PROP>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"
    local PROP="$3"

    case "$PARTITION" in
        system)
            FILE="${EXTRACTED_FIRM_DIR}/system/system/build.prop"
            ;;
        vendor)
            FILE="${EXTRACTED_FIRM_DIR}/vendor/build.prop"
            ;;
        product)
            FILE="${EXTRACTED_FIRM_DIR}/product/etc/build.prop"
            ;;
        system_ext)
            FILE="${EXTRACTED_FIRM_DIR}/system_ext/etc/build.prop"
            ;;
        odm)
            FILE="${EXTRACTED_FIRM_DIR}/odm/etc/build.prop"
            ;;
        *)
            echo -e "Unknown partition: $PARTITION"
            return 1
            ;;
    esac

    if [ ! -f "$FILE" ]; then
        echo -e "- File not found: $FILE"
        return 1
    fi

    local VALUE=$(grep -m1 "^${PROP}=" "$FILE" | cut -d'=' -f2-)

    if [ -z "$VALUE" ]; then
        return 1
    fi

    echo -e "$VALUE"
}


GET_FF_VALUE() {
    local KEY="$1"
    local FILE="$2"

    awk -F'[<>]' -v key="$KEY" '
        $2 == key { print $3; exit }
    ' "$FILE"
}


DETECT_FILESYSTEM() {
    local imgfile="$1"

    [ ! -f "$imgfile" ] && {
        echo "unknown"
        return 1
    }

    local fstype=$(blkid -o value -s TYPE "$imgfile" 2>/dev/null)
    [ -z "$fstype" ] && fstype=$(file -b "$imgfile" 2>/dev/null)

    case "$fstype" in
        *"Android sparse image"*)
            echo "sparse"
            ;;
        *"ext2"*)
            echo "ext2"
            ;;
        *"ext3"*)
            echo "ext3"
            ;;
        *"ext4"*)
            echo "ext4"
            ;;
        *"f2fs"*|*"F2FS"*)
            echo "f2fs"
            ;;
        *"erofs"*|*"EROFS"*)
            echo "erofs"
            ;;
        *"squashfs"*|*"Squashfs"*)
            echo "squashfs"
            ;;
        *"LZ4 compressed"*)
            echo "lz4"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}


DOWNLOAD_FIRMWARE() {
    echo " "

    if [ "$#" -lt 4 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <MODEL> <CSC> <IMEI> <DOWNLOAD_DIRECTORY> [VERSION]"
        return 1
    fi

    local MODEL="$1"
    local CSC="$2"
    local IMEI="$3"
    local DOWN_DIR="${4}/$MODEL"

    rm -rf "$DOWN_DIR"
    mkdir -p "$DOWN_DIR"

    echo -e "======================================"
    echo -e "  Samsung FW Downloader   "
    echo -e "======================================"
    echo -e "MODEL: $MODEL | CSC: $CSC"

    VERSION=$(python3 -m samloader -m "$MODEL" -r "$CSC" -i "$IMEI" checkupdate 2>&1)

    if [ $? -ne 0 ] || [ -z "$VERSION" ]; then
        echo -e "⛔️ MODEL/CSC/IMEI not valid or no update found."
        echo -e "Error: $VERSION"
        return 1
    fi

    if [ -n "$GITHUB_ENV" ]; then
        echo "VERSION=$VERSION" >> "$GITHUB_ENV"
    fi

    # --- Step 2: Download Firmware ---
    python3 -m samloader -m "$MODEL" -r "$CSC" -i "$IMEI" download -O "$DOWN_DIR"
    if [ $? -ne 0 ]; then
        echo -e "⛔️ Download failed. Check IMEI/MODEL/CSC."
        exit 1
    fi

	find "$DOWN_DIR" -type f -name "*.zip.enc*" -delete

    # --- Show Firmware Info ---
    local file_size=$(du -m "${DOWN_DIR}"/${MODEL}_*_fac.zip 2>/dev/null | cut -f1)
    echo -e "Firmware Size: ${file_size} MB"
}


EXTRACT_FIRMWARE() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"

    echo -e "Extracting downloaded firmware."

	if [ ! -d "$FIRM_DIR" ]; then
        echo -e "- Directory not found: $FIRM_DIR"
        exit
    fi

    # ---- ZIP ----
    for file in "$FIRM_DIR"/*.zip; do
        [ -e "$file" ] || continue

        echo -e "Extracting zip: $(basename "$file")"
        7z x -y -bd -bsp1 -o"$FIRM_DIR" "$file"

        rm -f "$file"
    done

    # remove unwanted archives before extraction
    rm -f "$FIRM_DIR"/BL_*.tar.md5
    rm -f "$FIRM_DIR"/CP_*.tar.md5
    rm -f "$FIRM_DIR"/HOME_CSC_*.tar.md5
	rm -f "$FIRM_DIR"/USERDATA_*.tar.md5

    # ---- XZ ----
    for file in "$FIRM_DIR"/*.xz; do
        [ -e "$file" ] || continue

        echo -e "Extracting xz: $(basename "$file")"
        7z x -y -bd -bsp1 -o"$FIRM_DIR" "$file"

        rm -f "$file"
    done

    # ---- RENAME .MD5 -> .TAR ----
    for file in "$FIRM_DIR"/*.md5; do
        [ -e "$file" ] || continue

        mv -- "$file" "${file%.md5}"
    done

    # ---- TAR ----
    for file in "$FIRM_DIR"/*.tar; do
        [ -e "$file" ] || continue

        echo -e "Extracting tar: $(basename "$file")"

        tar -xf "$file" -C "$FIRM_DIR"

        # remove only samsung firmware tar archives
        case "$(basename "$file")" in
            AP_*|BL_*|CP_*|CSC_*|HOME_CSC_*)
                rm -f "$file"
                ;;
        esac
    done

    # ---- REMOVE UNWANTED LZ4 FILES ----
    rm -rf \
        "$FIRM_DIR/meta-data" \
        "$FIRM_DIR"/*.txt \
        "$FIRM_DIR"/*.pit \
        "$FIRM_DIR"/*.bin \
        "$FIRM_DIR"/cache.img.lz4 \
        "$FIRM_DIR"/dtbo.img.lz4 \
        "$FIRM_DIR"/efuse.img.lz4 \
        "$FIRM_DIR"/gz-verified.img.lz4 \
        "$FIRM_DIR"/lk-verified.img.lz4 \
        "$FIRM_DIR"/md1img.img.lz4 \
        "$FIRM_DIR"/md_udc.img.lz4 \
        "$FIRM_DIR"/misc.bin.lz4 \
        "$FIRM_DIR"/omr.img.lz4 \
        "$FIRM_DIR"/param.bin.lz4 \
        "$FIRM_DIR"/preloader.img.lz4 \
        "$FIRM_DIR"/recovery.img.lz4 \
        "$FIRM_DIR"/scp-verified.img.lz4 \
        "$FIRM_DIR"/spmfw-verified.img.lz4 \
        "$FIRM_DIR"/sspm-verified.img.lz4 \
        "$FIRM_DIR"/tee-verified.img.lz4 \
        "$FIRM_DIR"/tzar.img.lz4 \
        "$FIRM_DIR"/up_param.bin.lz4 \
        "$FIRM_DIR"/userdata.img.lz4 \
        "$FIRM_DIR"/vbmeta.img.lz4 \
        "$FIRM_DIR"/vbmeta_system.img.lz4 \
        "$FIRM_DIR"/audio_dsp-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu1-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu2-verified.img.lz4 \
        "$FIRM_DIR"/cam_vpu3-verified.img.lz4 \
        "$FIRM_DIR"/dpm-verified.img.lz4 \
        "$FIRM_DIR"/init_boot.img.lz4 \
        "$FIRM_DIR"/mcupm-verified.img.lz4 \
        "$FIRM_DIR"/pi_img-verified.img.lz4 \
        "$FIRM_DIR"/uh.bin.lz4 \
        "$FIRM_DIR"/vendor_boot.img.lz4 \
        "$FIRM_DIR"/ssu.img.lz4

    # ---- LZ4 ----
    for file in "$FIRM_DIR"/*.lz4; do
        [ -e "$file" ] || continue

        echo -e "Extracting lz4: $(basename "$file")"

        lz4 -d "$file" "${file%.lz4}"

        rm -f "$file"
    done

    echo -e "Firmware Extraction complete."
}


EXTRACT_SUPER_IMG() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <FIRMWARE_DIRECTORY>"
        return 1
    fi

    local FIRM_DIR="$1"

    if [ -f "$FIRM_DIR/super.img" ]; then
        echo -e "Extracting super.img"
        if [ "$(DETECT_FILESYSTEM "$FIRM_DIR/super.img")" = "sparse" ]; then
		    echo -e "Converting to raw super.img"
            simg2img "$FIRM_DIR/super.img" "$FIRM_DIR/super_raw.img"
            rm -f "$FIRM_DIR/super.img"
            mv -f "$FIRM_DIR/super_raw.img" "$FIRM_DIR/super.img"
        fi

        echo "- Extracting partitions from super.img"
        "$lpunpack" "$FIRM_DIR/super.img" "$FIRM_DIR" || return 1
        rm -f "$FIRM_DIR/super.img"

        echo -e "super.img extraction complete"

    else
        echo -e "No super.img found."
    fi
}


PREPARE_PARTITIONS() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "Preparing partitions. $STOCK_DEVICE"
	
	if [ ! -d "$EXTRACTED_FIRM_DIR" ]; then
        echo -e "- Directory not found: $EXTRACTED_FIRM_DIR"
        return 1
    fi

    if [ -z "$STOCK_DEVICE" ] || [ "$STOCK_DEVICE" = "None" ]; then
        export BUILD_PARTITIONS="odm,odm_dlkm,product,system,system_ext,system_dlkm,vendor,vendor_dlkm,odm_a,odm_dlkm_a,product_a,system_a,system_ext_a,system_dlkm_a,vendor_a,vendor_dlkm_a,optics,optics_a"
    fi

    if [ -n "$STOCK_DEVICE" ] && [ -f "${DEVICES_DIR}/$STOCK_DEVICE/config" ]; then
        export STOCK_HAS_AB_SLOT="$(grep -m1 '^STOCK_HAS_AB_SLOT=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
    fi

	# Delete empty b slot images
    find "$EXTRACTED_FIRM_DIR" -type f -name '*_b.img' -size 0c -exec rm -rf {} +

    for img in "$EXTRACTED_FIRM_DIR"/*_a.img; do
        [ -f "$img" ] || continue

        new="${img%_a.img}.img"
        mv -f "$img" "$new"
    done

    IFS=',' read -r -a KEEP <<< "$BUILD_PARTITIONS"

    for i in "${!KEEP[@]}"; do
        KEEP[$i]=$(echo -e "${KEEP[$i]}" | xargs)
    done

    shopt -s nullglob dotglob

    for item in "$EXTRACTED_FIRM_DIR"/*; do
        base=$(basename "$item")

        [[ "$base" == *.img ]] && base="${base%.img}"

        keep_this=0
        for k in "${KEEP[@]}"; do
            [[ "$k" == "$base" ]] && keep_this=1 && break
        done

        if [[ $keep_this -eq 0 ]]; then
            rm -rf -- "$item"
        fi
    done

    shopt -u nullglob dotglob
}


EXTRACT_FIRMWARE_IMG() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> all|img_name"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local MODE="$2"

    if ! ls "$EXTRACTED_FIRM_DIR"/*.img >/dev/null 2>&1; then
        echo -e "No .img files found in: $EXTRACTED_FIRM_DIR"
        return 1
    fi

    echo -e "Extracting images from: $EXTRACTED_FIRM_DIR"

    extract_img() {
        local imgfile="$1"

        [ -e "$imgfile" ] || return

        local img_name="$(basename "$imgfile")"

        if [[ "$img_name" == "boot.img" || "$img_name" == "recovery.img" ]]; then
            echo -e "- Skipping $img_name"
            return
        fi

        local partition="$(basename "${imgfile%.img}")"
        local ORG_IMG_SIZE=$(stat -c%s -- "$imgfile")

        rm -rf "${EXTRACTED_FIRM_DIR}/$partition"

        local fstype=$(DETECT_FILESYSTEM "$imgfile")
        if [ "$fstype" = "sparse" ]; then
            echo -e "$partition.img is SPARSE. Converting to raw img."

            local tmp_raw="${imgfile}.raw"

            if ! simg2img "$imgfile" "$tmp_raw" >/dev/null 2>&1; then
                echo -e "Failed to convert sparse image: $img_name"
                return
            fi

            if [ ! -f "$tmp_raw" ]; then
                echo -e "- Sparse conversion output missing: $tmp_raw"
                return
            fi

            rm -f "$imgfile"
            mv "$tmp_raw" "$imgfile"
        fi

        local fstype=$(DETECT_FILESYSTEM "$imgfile")

        case "$fstype" in
            ext4)
                echo " "
                echo -e "$partition.img Detected ext4. Size: $ORG_IMG_SIZE bytes. Extracting..."
                python3 "$imgextractor_py" "$imgfile" "$EXTRACTED_FIRM_DIR"
                ;;

            erofs)
                echo " "
                echo -e "$partition.img Detected erofs. Size: $ORG_IMG_SIZE bytes. Extracting..."
                "$extract_erofs" -i "$imgfile" -x -f -o "$EXTRACTED_FIRM_DIR" >/dev/null 2>&1
                ;;

            f2fs)
                echo " "
                echo -e "$partition.img Detected f2fs. Size: $ORG_IMG_SIZE bytes. Extracting..."
                bash "$QT_DIR/scripts/extract_img.sh" "$imgfile" "$EXTRACTED_FIRM_DIR"
                ;;

            *)
                echo -e "- $img_name unsupported filesystem type: ($fstype), skipping"
                ;;
        esac
    }

    if [ "$MODE" = "all" ]; then
	    PREPARE_PARTITIONS "$EXTRACTED_FIRM_DIR"
        for imgfile in "$EXTRACTED_FIRM_DIR"/*.img; do
            [ -e "$imgfile" ] || continue
            extract_img "$imgfile"
        done

	    rm -rf "$EXTRACTED_FIRM_DIR"/*.img

    else
        local TARGET_IMG="${EXTRACTED_FIRM_DIR}/$MODE"

        if [ ! -f "$TARGET_IMG" ]; then
            echo -e "- Image not found: $TARGET_IMG"
            return 1
        fi

        extract_img "$TARGET_IMG"
    fi

    chown -R "$REAL_USER:$REAL_USER" "$EXTRACTED_FIRM_DIR"
    chmod -R u+rwX "$EXTRACTED_FIRM_DIR"
}

FIX_VNDK() {
    echo " "

	if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIRECTORY>"
        return 1
    fi

	local EXTRACTED_FIRM_DIR="$1"
	local TARGET_ROM_SYSTEM_EXT_DIR="$(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"

    echo -e "Checking $STOCK_DEVICE and $TARGET_DEVICE vndk version."
    export SDK="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" ro.build.version.sdk_full)"
	echo "- Target rom SDK version: $SDK"
    if [ -f "${TARGET_ROM_SYSTEM_EXT_DIR}/apex/com.android.vndk.v${STOCK_VNDK_VERSION}.apex" ]; then
        echo -e "- VNDK matched. ${TARGET_ROM_SYSTEM_EXT_DIR}/apex/com.android.vndk.v${STOCK_VNDK_VERSION}.apex"
    else
        echo -e "- VNDK mismatch. Adding SDK $SDK com.android.vndk.v${STOCK_VNDK_VERSION}.apex"
        rm -rf "${TARGET_ROM_SYSTEM_EXT_DIR}/apex"
        7z x "$VNDKS_COLLECTION/$SDK/${STOCK_VNDK_VERSION}.zip" -o"${TARGET_ROM_SYSTEM_EXT_DIR}/" -y >/dev/null 2>&1
    fi
}


ADD_SYSTEM_EXT_IN_SYSTEM_ROOT() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    echo -e "- Copying system_ext content into system root"
    rm -rf "${EXTRACTED_FIRM_DIR}/system/system_ext"
    mv "${EXTRACTED_FIRM_DIR}/system_ext" "${EXTRACTED_FIRM_DIR}/system"

    echo -e "- Cleaning and merging system_ext file contexts and configs"
    # File paths
    SYSTEM_EXT_CONFIG_FILE="${EXTRACTED_FIRM_DIR}/config/system_ext_fs_config"
    SYSTEM_EXT_CONTEXTS_FILE="${EXTRACTED_FIRM_DIR}/config/system_ext_file_contexts"

    SYSTEM_CONFIG_FILE="${EXTRACTED_FIRM_DIR}/config/system_fs_config"
    SYSTEM_CONTEXTS_FILE="${EXTRACTED_FIRM_DIR}/config/system_file_contexts"

    SYSTEM_EXT_TEMP_CONFIG="${SYSTEM_EXT_CONFIG_FILE}.tmp"
    SYSTEM_EXT_TEMP_CONTEXTS="${SYSTEM_EXT_CONTEXTS_FILE}.tmp"

    # Clean system_ext contexts
    grep -v '^/ u:object_r:system_file:s0$' "$SYSTEM_EXT_CONTEXTS_FILE" \
    | grep -v '^/system_ext u:object_r:system_file:s0$' \
    | grep -v '^/system_ext(.*)? u:object_r:system_file:s0$' \
    | grep -v '^/system_ext/ u:object_r:system_file:s0$' \
    > "$SYSTEM_EXT_TEMP_CONTEXTS" && mv "$SYSTEM_EXT_TEMP_CONTEXTS" "$SYSTEM_EXT_CONTEXTS_FILE"

    # Clean system_ext config
    grep -v '^/ 0 0 0755$' "$SYSTEM_EXT_CONFIG_FILE" \
    | grep -v '^system_ext/ 0 0 0755$' \
    > "$SYSTEM_EXT_TEMP_CONFIG" && mv "$SYSTEM_EXT_TEMP_CONFIG" "$SYSTEM_EXT_CONFIG_FILE"

    # Fix system_ext config
    awk '{print "system/" $0}' "$SYSTEM_EXT_CONFIG_FILE" \
    > "$SYSTEM_EXT_TEMP_CONFIG" && mv "$SYSTEM_EXT_TEMP_CONFIG" "$SYSTEM_EXT_CONFIG_FILE"

    # Fix system_ext contexts
    awk '{print "/system" $0}' "$SYSTEM_EXT_CONTEXTS_FILE" \
    > "$SYSTEM_EXT_TEMP_CONTEXTS" && mv "$SYSTEM_EXT_TEMP_CONTEXTS" "$SYSTEM_EXT_CONTEXTS_FILE"

    # Append cleaned system_ext config into system config
    cat "$SYSTEM_EXT_CONFIG_FILE" >> "$SYSTEM_CONFIG_FILE"

    # Append cleaned system_ext contexts into system contexts
    cat "$SYSTEM_EXT_CONTEXTS_FILE" >> "$SYSTEM_CONTEXTS_FILE"

    rm -rf "$EXTRACTED_FIRM_DIR"/config/system_ext*
    export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
}


SEPARATE_SYSTEM_EXT() {
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

	echo "- Separating system_ext"
    mv "${EXTRACTED_FIRM_DIR}/system/system/system_ext" "${EXTRACTED_FIRM_DIR}/"
	ln -s /system_ext ${EXTRACTED_FIRM_DIR}/system/system/system_ext
	rm -rf "${EXTRACTED_FIRM_DIR}/system/system_ext"
	mkdir "${EXTRACTED_FIRM_DIR}/system/system_ext"

    SYSTEM_FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/system_fs_config"
	SYSTEM_FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/system_file_contexts"
    
	SYSTEM_EXT_FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/system_ext_fs_config"
	SYSTEM_EXT_FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/system_ext_file_contexts"

    # Process system_ext_file_contexts
    if grep -q '^/system/system/system_ext' "$SYSTEM_FILE_CONTEXTS"; then
        grep '^/system/system/system_ext' "$SYSTEM_FILE_CONTEXTS" > "$SYSTEM_EXT_FILE_CONTEXTS"
        sed -i '\|^/system/system/system_ext|d' "$SYSTEM_FILE_CONTEXTS"
        awk '{sub(/^\/system\/system\/system_ext/, "/system_ext"); print}' "$SYSTEM_EXT_FILE_CONTEXTS" > "$SYSTEM_EXT_FILE_CONTEXTS.tmp"  && \
        mv "$SYSTEM_EXT_FILE_CONTEXTS.tmp" "$SYSTEM_EXT_FILE_CONTEXTS"

        # Add object context line if missing
		grep -qxF '/system/system_ext u:object_r:system_file:s0' "$SYSTEM_FILE_CONTEXTS" || echo '/system/system_ext u:object_r:system_file:s0' >> "$SYSTEM_FILE_CONTEXTS"
		grep -qxF '/system/system/system_ext u:object_r:system_file:s0' "$SYSTEM_EXT_FILE_CONTEXTS" || echo '/system/system/system_ext u:object_r:system_file:s0' >> "$SYSTEM_EXT_FILE_CONTEXTS"

        grep -qxF '/ u:object_r:system_file:s0' "$SYSTEM_EXT_FILE_CONTEXTS" || echo '/ u:object_r:system_file:s0' >> "$SYSTEM_EXT_FILE_CONTEXTS"
		sort -u "$SYSTEM_EXT_FILE_CONTEXTS" -o "$SYSTEM_EXT_FILE_CONTEXTS"
    fi

    # Process system_ext_fs_config
    if grep -q '^system/system/system_ext' "$SYSTEM_FS_CONFIG"; then
        grep '^system/system/system_ext' "$SYSTEM_FS_CONFIG" > "$SYSTEM_EXT_FS_CONFIG"
        sed -i '\|^system/system/system_ext|d' "$SYSTEM_FS_CONFIG"
        awk '{sub(/^system\/system\/system_ext/, "system_ext"); print}' "$SYSTEM_EXT_FS_CONFIG" > "$SYSTEM_EXT_FS_CONFIG.tmp" &&  \
	    mv "$SYSTEM_EXT_FS_CONFIG.tmp" "$SYSTEM_EXT_FS_CONFIG"

        # Add default fs permissions if missing
        grep -qxF 'system/system_ext 0 0 0755' "$SYSTEM_FS_CONFIG" || echo 'system/system_ext 0 0 0755' >> "$SYSTEM_FS_CONFIG"
		grep -qxF 'system/system/system_ext 0 0 0644' "$SYSTEM_FS_CONFIG" || echo 'system/system/system_ext 0 0 0644' >> "$SYSTEM_FS_CONFIG"

        grep -qxF '/ 0 0 0755' "$SYSTEM_EXT_FS_CONFIG" || echo '/ 0 0 0755' >> "$SYSTEM_EXT_FS_CONFIG"
        grep -qxF 'system_ext/ 0 0 0755' "$SYSTEM_EXT_FS_CONFIG" || echo 'system_ext/ 0 0 0755' >> "$SYSTEM_EXT_FS_CONFIG"
		sort -u "$SYSTEM_EXT_FS_CONFIG" -o "$SYSTEM_EXT_FS_CONFIG"
    fi

    export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system_ext"
}


ADJUST_SYSTEM_EXT() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    if [ "$STOCK_HAS_SEPARATE_SYSTEM_EXT" = "FALSE" ]; then
        echo "- STOCK_HAS_SEPARATE_SYSTEM_EXT: $STOCK_HAS_SEPARATE_SYSTEM_EXT"

        if [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
            export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system/system_ext"

        elif [ -d "${EXTRACTED_FIRM_DIR}/system/system_ext/etc" ]; then
            export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
			
		elif [ -d "${EXTRACTED_FIRM_DIR}/system_ext/etc" ]; then
		    ADD_SYSTEM_EXT_IN_SYSTEM_ROOT "$EXTRACTED_FIRM_DIR"
        fi

	elif [ "$STOCK_HAS_SEPARATE_SYSTEM_EXT" = "TRUE" ]; then
        echo "STOCK_HAS_SEPARATE_SYSTEM_EXT: $STOCK_HAS_SEPARATE_SYSTEM_EXT"

        if [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
            SEPARATE_SYSTEM_EXT "$EXTRACTED_FIRM_DIR"
        fi
    fi

    echo "- TARGET_ROM_SYSTEM_EXT_DIR set to: $TARGET_ROM_SYSTEM_EXT_DIR"
}


GET_SYSTEM_EXT_DIR() {
    if [ "$#" -ne 1 ]; then
        echo "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"

    if [ -d "${EXTRACTED_FIRM_DIR}/system_ext/etc" ]; then
        export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system_ext"
    elif [ -d "${EXTRACTED_FIRM_DIR}/system/system_ext/etc" ]; then
        export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system_ext"
    elif [ -d "${EXTRACTED_FIRM_DIR}/system/system/system_ext/etc" ]; then
        export TARGET_ROM_SYSTEM_EXT_DIR="${EXTRACTED_FIRM_DIR}/system/system/system_ext"
    else
        return 1
    fi

    echo "$TARGET_ROM_SYSTEM_EXT_DIR"
}

PATCH_SELINUX() {
    echo " "

    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local TARGET_ROM_SYSTEM_EXT_DIR
    TARGET_ROM_SYSTEM_EXT_DIR="$(GET_SYSTEM_EXT_DIR "$EXTRACTED_FIRM_DIR")"

    if [ -z "$TARGET_ROM_SYSTEM_EXT_DIR" ]; then
        echo -e "ERROR: Failed to determine system_ext directory."
        return 1
    fi

    echo -e "Patching selinux."

    local UNSUPPORTED_SELINUX=(
        "audiomirroring"
        "fabriccrypto"
        "hal_dsms_default"
        "qb_id_prop"
        "hal_dsms_service"
        "proc_compaction_proactiveness"
        "sbauth"
        "ker_app"
        "kpp_app"
        "kpp_data"
        "attiqi_app"
        "kpoc_charger"
        "sec_diag"
        "mosey_app"
    )

    # Patch system partition SELinux policies
    if [ -d "${EXTRACTED_FIRM_DIR}/system" ]; then
        echo "- Patching selinux for system"

        local SYSTEM_PLAT_SEPOLICY="${EXTRACTED_FIRM_DIR}/system/system/etc/selinux/plat_sepolicy.cil"
        
        if [ -f "$SYSTEM_PLAT_SEPOLICY" ]; then
            REMOVE_LINE '(genfscon sysfs "/bus/usb/devices" (u object_r sysfs_usb ((s0) (s0))))' \
                "$SYSTEM_PLAT_SEPOLICY" >/dev/null 2>&1
            
            REMOVE_LINE '(genfscon proc "/sys/vm/compaction_proactiveness" (u object_r proc_compaction_proactiveness ((s0) (s0))))' \
                "$SYSTEM_PLAT_SEPOLICY" >/dev/null 2>&1
        else
            echo "  WARNING: plat_sepolicy.cil not found in system partition."
        fi
    else
        echo -e "- No system directory found."
    fi

    # Patch system_ext partition SELinux policies
    if [ -d "$TARGET_ROM_SYSTEM_EXT_DIR" ]; then
        echo -e "- Patching selinux for system_ext."

        local MAPPING_DIR="${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/mapping/"
        
        if [ -d "$MAPPING_DIR" ]; then
            # Process all .cil files in mapping directory, including 202404.cil and *.0.cil
            find "$MAPPING_DIR" -type f -name "*.cil" | while IFS= read -r SELINUX_FILE; do
                local BASENAME
                BASENAME="$(basename "$SELINUX_FILE")"
                echo "  - Processing mapping file: $BASENAME"

                for keyword in "${UNSUPPORTED_SELINUX[@]}"; do
                    if grep -qF "$keyword" "$SELINUX_FILE"; then
                        sed -i "/$keyword/d" "$SELINUX_FILE"
                        echo "    - Removed: $keyword"
                    fi
                done
            done
        else
            echo "  WARNING: Mapping directory not found in system_ext."
        fi

        # Remove specific genfscon entries from system_ext_sepolicy.cil
        local SYSTEM_EXT_SEPOLICY="${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/system_ext_sepolicy.cil"
        if [ -f "$SYSTEM_EXT_SEPOLICY" ]; then
            REMOVE_LINE '(genfscon proc "/sys/kernel/firmware_config" (u object_r proc_fmw ((s0) (s0))))' \
                "$SYSTEM_EXT_SEPOLICY" >/dev/null 2>&1
            
            REMOVE_LINE '(genfscon proc "/sys/vm/compaction_proactiveness" (u object_r proc_compaction_proactiveness ((s0) (s0))))' \
                "$SYSTEM_EXT_SEPOLICY" >/dev/null 2>&1
        else
            echo "  WARNING: system_ext_sepolicy.cil not found."
        fi

        # Remove property context entry
        local SYSTEM_EXT_PROPERTY_CONTEXTS="${TARGET_ROM_SYSTEM_EXT_DIR}/etc/selinux/system_ext_property_contexts"
        if [ -f "$SYSTEM_EXT_PROPERTY_CONTEXTS" ]; then
            REMOVE_LINE 'init.svc.vendor.wvkprov_server_hal                           u:object_r:wvkprov_prop:s0' \
                "$SYSTEM_EXT_PROPERTY_CONTEXTS" >/dev/null 2>&1
        else
            echo "  WARNING: system_ext_property_contexts not found."
        fi
    else
        echo -e "- No system_ext directory found."
    fi

    echo "- SELinux patching completed."
}

APPLY_STOCK_CONFIG() {
    echo " "

	echo -e "Applying $STOCK_DEVICE device config."
    if [ "$#" -ne 1 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
	local FLOATING_FEATURE_FILE_DIRECTORY="${EXTRACTED_FIRM_DIR}/system/system/etc/floating_feature.xml"
	export TARGET_ROM_CPU_ABILIST="$(GET_PROP "$EXTRACTED_FIRM_DIR" "system" ro.system.product.cpu.abilist)"

	if [ -z "$STOCK_DEVICE" ] || [ "$STOCK_DEVICE" = "None" ]; then
        echo -e "No target device is set. Just modifying ROM without any device config."
        return 1
    fi

    if [ ! -f "${DEVICES_DIR}/$STOCK_DEVICE/config" ]; then
        echo -e "Config file for $STOCK_DEVICE not found in $DEVICES_DIR"
        return 1
	fi

    if [ ! -d "${EXTRACTED_FIRM_DIR}/system/system" ]; then
        echo -e "No usable extracted firmware found"
        return 1
	fi

    if [ -f "${DEVICES_DIR}/$STOCK_DEVICE/config" ]; then
        echo -e "$STOCK_DEVICE config found."
        export STOCK_VNDK_VERSION="$(grep -m1 '^STOCK_VNDK_VERSION=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
        export STOCK_HAS_SEPARATE_SYSTEM_EXT="$(grep -m1 '^STOCK_HAS_SEPARATE_SYSTEM_EXT=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
    	export STOCK_DVFS_FILENAME="$(grep -m1 '^STOCK_DVFS_FILENAME=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
		export STOCK_DEVICE_CPU_ABILIST="$(grep -m1 '^STOCK_DEVICE_CPU_ABILIST=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
		export STOCK_DEVICE_CHIPSET="$(grep -m1 '^STOCK_DEVICE_CHIPSET=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
		export USE_ALT_SDHMS_APP="$(grep -m1 '^USE_ALT_SDHMS_APP=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
		export STOCK_HAS_ESIM_SUPPORT="$(grep -m1 '^STOCK_HAS_ESIM_SUPPORT=' "${DEVICES_DIR}/$STOCK_DEVICE/config" | cut -d= -f2 | tr -d '\r')"
    fi

	echo "Stock device vndk version: $STOCK_VNDK_VERSION"
    export STOCK_ROM_FLOATING_FEATURE="${DEVICES_DIR}/$STOCK_DEVICE/floating_feature.xml"
	export STOCK_SIOP_POLICY_FILENAME="$(awk -F'[<>]' '$2 == "SEC_FLOATING_FEATURE_SYSTEM_CONFIG_SIOP_POLICY_FILENAME" {print $3}' "$STOCK_ROM_FLOATING_FEATURE" | tr -d '\r' | xargs)"
	export STOCK_DEVICE_TYPE="$(awk -F'[<>]' '$2 == "SEC_FLOATING_FEATURE_COMMON_CONFIG_DEVICE_MANUFACTURING_TYPE" {print $3}' "$STOCK_ROM_FLOATING_FEATURE")"

	if [ "$STOCK_DEVICE_CPU_ABILIST" != "$TARGET_ROM_CPU_ABILIST" ]; then
        echo "CPU ABI MISMATCH!"
        echo "STOCK DEVICE CPU ABI: $STOCK_DEVICE_CPU_ABILIST"
        echo "TARGET ROM CPU ABI  : $TARGET_ROM_CPU_ABILIST"
        exit 1
    fi

    # Remove ESIM files if stock device does not support.
    if [ "$STOCK_HAS_ESIM_SUPPORT" = "FALSE" ]; then
        REMOVE_ESIM_FILES "$EXTRACTED_FIRM_DIR"
    fi

	# ADJUST SYSTEM_EXT PARTITION.
    ADJUST_SYSTEM_EXT "$EXTRACTED_FIRM_DIR"

	# FIX VNDK.
	FIX_VNDK "$EXTRACTED_FIRM_DIR"

	# FIX CAMERA IF NEED
	FIX_CAMERA "$EXTRACTED_FIRM_DIR"

    # Apply stock floating feature.
	APPLY_STOCK_ROM_FLOATING_FEATURE "$FLOATING_FEATURE_FILE_DIRECTORY"

    # Fix unsupported BPF error for kernels lower than 5.10.
    if [ "$USE_UI_8_TETHERING_APEX" = "True" ]; then
        cp -rfa "$(pwd)/QuantumROM/Mods/Tethering_Apex/UI-8/." "${EXTRACTED_FIRM_DIR}/"
    fi

    if [ "$STOCK_DEVICE_TYPE" = "jdm" ]; then
	    echo -e "Applying jdm device feature."
	    APPLY_JDM_SPECIAL "$EXTRACTED_FIRM_DIR"
    else
	    rm -rf "${EXTRACTED_FIRM_DIR}/system/system/cameradata/portrait_data"
	fi

	rm -rf "${EXTRACTED_FIRM_DIR}/system/system/etc/init"/rscmgr*.rc
	find "${EXTRACTED_FIRM_DIR}/system/system/media" -maxdepth 1 -type f \( -iname "*.spi" -o -iname "*.qmg" -o -iname "*.txt" \) -delete
	rm -rf "$EXTRACTED_FIRM_DIR"/product/overlay/framework-res*auto_generated_rro_product.apk
	rm -rf ${EXTRACTED_FIRM_DIR}/product/overlay/SystemUI*auto_generated_rro_product.apk
	cp -a "${DEVICES_DIR}/$STOCK_DEVICE/Stock/." "${EXTRACTED_FIRM_DIR}/"
    if [ -d "${DEVICES_DIR}/$STOCK_DEVICE/extra" ]; then
        cp -af "${DEVICES_DIR}/$STOCK_DEVICE/extra/." "$(pwd)/OUT"
    fi

	BUILD_PROP "$EXTRACTED_FIRM_DIR" "system" "ro.product.system.model" "$STOCK_DEVICE"
}

BUILD_PROP() {
    if [ "$#" -lt 3 ]; then
        echo -e "Usage: BUILD_PROP <EXTRACTED_FIRM_DIR> <PARTITION> <KEY> [VALUE]"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"
    local KEY="$3"
    local VALUE="${4-}"

    local FILE=""

    case "$PARTITION" in
        system)
            local FILE="${EXTRACTED_FIRM_DIR}/system/system/build.prop"
            ;;
        vendor)
            local FILE="${EXTRACTED_FIRM_DIR}/vendor/build.prop"
            ;;
        product)
            local FILE="${EXTRACTED_FIRM_DIR}/product/etc/build.prop"
            ;;
        system_ext)
            local FILE="${EXTRACTED_FIRM_DIR}/system_ext/etc/build.prop"
            ;;
        odm)
            local FILE="${EXTRACTED_FIRM_DIR}/odm/etc/build.prop"
            ;;
        *)
            echo -e "Unknown partition: $PARTITION"
            return 1
            ;;
    esac

    if [ ! -f "$FILE" ]; then
        echo -e "- File not found: $FILE"
        return 1
    fi

    if grep -q "^${KEY}=" "$FILE"; then
        if [ -z "$VALUE" ]; then
            # Keep key, remove value
            sed -i "s|^${KEY}=.*|${KEY}=|" "$FILE"
        else
            # Replace value
            sed -i "s|^${KEY}=.*|${KEY}=${VALUE}|" "$FILE"
        fi
    else
        # Append if not exists
        if [ -z "$VALUE" ]; then
            echo -e "${KEY}=" >> "$FILE"
        else
            echo -e "${KEY}=${VALUE}" >> "$FILE"
        fi
    fi
}

GEN_FS_CONFIG() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION_FOLDER_NAME>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"

    [ ! -d "${EXTRACTED_FIRM_DIR}/$PARTITION" ] && {
        echo -e "- Partition not found: $PARTITION"
        return 1
    }

    [ "$PARTITION" = "config" ] && return

    local FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_fs_config"
    local TMP_EXISTING="$(mktemp)"

    touch "$FS_CONFIG"

    echo -e "Generating fs_config for partition: $PARTITION"

    awk '{print $1}' "$FS_CONFIG" | sort -u > "$TMP_EXISTING"

    find "${EXTRACTED_FIRM_DIR}/$PARTITION" -mindepth 1 \( -type f -o -type d -o -type l \) | while IFS= read -r item; do

        REL_PATH="${item#${EXTRACTED_FIRM_DIR}/$PARTITION/}"
        PATH_ENTRY="$PARTITION/$REL_PATH"

        grep -qxF "$PATH_ENTRY" "$TMP_EXISTING" && continue

        if [ -d "$item" ]; then
            echo -e "- Adding: $PATH_ENTRY 0 0 0755"
            printf "%s 0 0 0755\n" "$PATH_ENTRY" >> "$FS_CONFIG"

        else
            if [[ "$REL_PATH" == */bin/* ]]; then
                echo -e "- Adding: $PATH_ENTRY 0 2000 0755"
                printf "%s 0 2000 0755\n" "$PATH_ENTRY" >> "$FS_CONFIG"
            else
                echo -e "- Adding: $PATH_ENTRY 0 0 0644"
                printf "%s 0 0 0644\n" "$PATH_ENTRY" >> "$FS_CONFIG"
            fi
        fi

    done

    rm -f "$TMP_EXISTING"

    echo -e "- $PARTITION fs_config generated"
}


GEN_FILE_CONTEXTS() {
    echo " "

    if [ "$#" -ne 2 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> <PARTITION_FOLDER_NAME>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local PARTITION="$2"

    [ ! -d "${EXTRACTED_FIRM_DIR}/$PARTITION" ] && {
        echo -e "- Partition not found: $PARTITION"
        return 1
    }

    [ "$PARTITION" = "config" ] && return

    escape_path() {
        local path="$1"
        local result=""
        local c

        for ((i=0; i<${#path}; i++)); do
            c="${path:i:1}"

            case "$c" in
                '.'|'+'|'['|']'|'*'|'?'|'^'|'$'|'\\')
                    result+="\\$c"
                    ;;
                *)
                    result+="$c"
                    ;;
            esac
        done

        printf '%s' "$result"
    }

    local FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_file_contexts"

    touch "$FILE_CONTEXTS"

    echo -e "Generating file_contexts for partition: $PARTITION"

    declare -A EXISTING=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        [ -z "$line" ] && continue

        local PATH_ONLY=$(echo -e "$line" | awk '{print $1}')

        EXISTING["$PATH_ONLY"]=1

    done < "$FILE_CONTEXTS"

    find "${EXTRACTED_FIRM_DIR}/$PARTITION" -mindepth 1 \( -type f -o -type d -o -type l \) | while IFS= read -r item; do

        local REL_PATH="${item#${EXTRACTED_FIRM_DIR}/$PARTITION}"
        local PATH_ENTRY="/$PARTITION$REL_PATH"

        local ESCAPED_PATH="/$(escape_path "${PATH_ENTRY#/}")"

        [[ -n "${EXISTING[$ESCAPED_PATH]-}" ]] && continue

        local CONTEXT="u:object_r:system_file:s0"
        
        if [[ "$PARTITION" == odm* || "$PARTITION" == vendor* ]]; then
            CONTEXT="u:object_r:vendor_file:s0"
        fi

        local BASENAME=$(basename "$item")

        if [[ "$BASENAME" == "linker" || "$BASENAME" == "linker64" ]]; then
            CONTEXT="u:object_r:system_linker_exec:s0"
        fi

        if [[ "$BASENAME" == "[" ]]; then
            CONTEXT="u:object_r:system_file:s0"
        fi

        printf "%s %s\n" "$ESCAPED_PATH" "$CONTEXT" >> "$FILE_CONTEXTS"

        echo -e "- Added: $ESCAPED_PATH"

        EXISTING["$ESCAPED_PATH"]=1

    done

    echo -e "- $PARTITION file_contexts generated"

    unset EXISTING
}


BUILD_IMG() {
    echo " "

    if [ "$#" -ne 4 ]; then
        echo -e "Usage: ${FUNCNAME[0]} <EXTRACTED_FIRM_DIR> all|img_name <FILE_SYSTEM> <OUT_DIR>"
        return 1
    fi

    local EXTRACTED_FIRM_DIR="$1"
    local MODE="$2"
    local FILE_SYSTEM="$3"
    local OUT_DIR="$4"

    mkdir -p "$OUT_DIR"

    build_img() {
        local PARTITION="$1"

        mkdir -p "${EXTRACTED_FIRM_DIR}/${PARTITION}/lost+found"

        GEN_FS_CONFIG "$EXTRACTED_FIRM_DIR" "$PARTITION"
        GEN_FILE_CONTEXTS "$EXTRACTED_FIRM_DIR" "$PARTITION"

        local SOURCE_DIR="${EXTRACTED_FIRM_DIR}/$PARTITION"
        local OUT_IMG="$OUT_DIR/${PARTITION}.img"
        local FS_CONFIG="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_fs_config"
        local FILE_CONTEXTS="${EXTRACTED_FIRM_DIR}/config/${PARTITION}_file_contexts"

        [[ -d "$SOURCE_DIR" ]] || return

        local EXTRACTED_SIZE=$(du -sb --apparent-size "$SOURCE_DIR" | cut -f1)
        local MOUNT_POINT="/$PARTITION"

        rm -rf "$OUT_IMG"

        [[ -f "$FS_CONFIG" ]] || {
            echo -e "Warning: $FS_CONFIG missing, skipping $PARTITION"
            return
        }

        [[ -f "$FILE_CONTEXTS" ]] || {
            echo -e "Warning: $FILE_CONTEXTS missing, skipping $PARTITION"
            return
        }

        sort -u "$FILE_CONTEXTS" -o "$FILE_CONTEXTS"
        sort -u "$FS_CONFIG" -o "$FS_CONFIG"

        if [[ "$FILE_SYSTEM" == "erofs" ]]; then
            echo " "
            echo -e "Building erofs image: $OUT_IMG"

            $mkfs_erofs \
                --mount-point="$MOUNT_POINT" \
                --fs-config-file="$FS_CONFIG" \
                --file-contexts="$FILE_CONTEXTS" \
                -z lz4hc \
                -b 4096 \
                -T 1199145600 \
                "$OUT_IMG" "$SOURCE_DIR" >/dev/null 2>&1

        elif [[ "$FILE_SYSTEM" == "ext4" ]]; then
            echo " "
            echo -e "Building ext4 image: $OUT_IMG"

            SIZE=$(((EXTRACTED_SIZE + 4095) / 4096 * 4096))
            EXTENDED_SIZE=$((SIZE + SIZE / 5))

            if [ "$EXTENDED_SIZE" -lt "4349952" ]; then
                EXTENDED_SIZE="4349952"
            fi

            $make_ext4fs \
                -l "$EXTENDED_SIZE" \
                -J \
                -b 4096 \
                -S "$FILE_CONTEXTS" \
                -C "$FS_CONFIG" \
                -a "$MOUNT_POINT" \
                -L "$PARTITION" \
                "$OUT_IMG" "$SOURCE_DIR"

            resize2fs -M "$OUT_IMG"

        elif [[ "$FILE_SYSTEM" == "f2fs" ]]; then
            echo " "
            echo -e "Building f2fs image: $OUT_IMG"

            SIZE=$(((EXTRACTED_SIZE + 511) / 512 * 512))
            EXTENDED_SIZE=$((SIZE + SIZE / 4))

            dd if=/dev/zero of="$OUT_IMG" bs=512 count=$((EXTENDED_SIZE / 512))

            $make_f2fs \
                -f -q \
                -g android \
                -O extra_attr,inode_checksum,sb_checksum,compression \
                -l "$MOUNT_POINT" \
                "$OUT_IMG"

            $sload_f2fs \
                -f "$SOURCE_DIR" \
                -C "$FS_CONFIG" \
                -s "$FILE_CONTEXTS" \
                -t "$MOUNT_POINT" \
                -P \
                -c \
                -L 2 \
                -a lz4 \
                "$OUT_IMG"

            img2simg "$OUT_IMG" "${OUT_IMG}.sparse"

            rm -rf "$OUT_IMG"
            mv "${OUT_IMG}.sparse" "$OUT_IMG"

        else
            echo -e "Unsupported filesystem: $FILE_SYSTEM"
            return
        fi
    }

    if [ "$MODE" = "all" ]; then

        for PART in "$EXTRACTED_FIRM_DIR"/*; do
            [[ -d "$PART" ]] || continue

            local PARTITION="$(basename "$PART")"

            [[ "$PARTITION" == "config" ]] && continue

            build_img "$PARTITION"
        done

    else
        build_img "$MODE"
    fi

    chown -R "$REAL_USER:$REAL_USER" "$OUT_DIR"
    chmod -R u+rwX "$OUT_DIR"
}


BUILD_SUPER_IMG() {
    echo " "

    local IMG_DIR="$1"
    local OUTPUT_DIR="$2"
    local OUTPUT_IMG="$OUTPUT_DIR/super.img"

    echo "Building: super.img"

    [ ! -d "$IMG_DIR" ] && {
        echo "- Input folder not found: $IMG_DIR"
        return 1
    }

    local PARTITIONS=""
    local IMAGES=""
    local TOTAL_SIZE=0
    local VALID_IMAGES=0

    rm -f "$OUTPUT_IMG"

    for img in "$IMG_DIR"/*.img; do
        [ -e "$img" ] || continue

        local name="$(basename "$img")"

        case "$name" in
            boot.img|init_boot.img|recovery.img|vbmeta.img|vbmeta_system.img|vbmeta_vendor.img|dtbo.img|userdata.img|cache.img|metadata.img|vendor_boot.img|super.img)
                echo "- Skipping $name"
                continue
                ;;
        esac

        local part_name="${name%.img}"
        local size=$(stat -c%s "$img")

        [ "$size" -le 0 ] && {
            echo "- Skipping empty image: $name"
            continue
        }

        echo "Adding: $part_name ($size bytes)"

        PARTITIONS+=" --partition ${part_name}:readonly:${size}:main"
        IMAGES+=" --image ${part_name}=$img"
        TOTAL_SIZE=$((TOTAL_SIZE + size))
        VALID_IMAGES=1
    done

    [ "$VALID_IMAGES" -eq 0 ] && {
        echo "- No valid logical partition images found"
        return 1
    }

    TOTAL_SIZE=$((TOTAL_SIZE + 4194304))

    $lpmake \
	    --device super:$TOTAL_SIZE \
        --metadata-size 65536 \
        --metadata-slots 2 \
		--group main:$TOTAL_SIZE \
		--block-size 4096 \
        $PARTITIONS \
        $IMAGES \
        --output "$OUTPUT_IMG"
}
