#!/bin/bash
set -e

# Usage: ./build.sh <ABI> [TAG_NAME]
#   ABI: arm64-v8a | armv7a | x86 | x86_64
ABI=$1
TAG_NAME=${TAG_NAME:-$2}

MODULE_DIR=ksu-rclone
REPO=visionsong/rclone-fuse3-ksu

# 从 ksu-rclone/module.prop 文件中读取版本信息
RCLONE_VERSION=$(grep -oP '^version=\Kv.*' $MODULE_DIR/module.prop)
VERSION_CODE=$(grep -oP '^versionCode=\K.*' $MODULE_DIR/module.prop)

# 复制目录并准备环境
BUILD_DIR=${MODULE_DIR}_$ABI
rm -rf "$BUILD_DIR"
cp $MODULE_DIR "$BUILD_DIR" -r

# 二进制必须落在 system/bin：KernelSU 不会挂载 system/vendor，
# 往 /vendor 叠 overlay 会触发 SELinux / dm-verity 问题（原版无限重启的根因）。
./scripts/download-rclone.sh $ABI $RCLONE_VERSION "$BUILD_DIR/system/bin/rclone"

./scripts/build-libfuse3.sh $ABI
cp libfuse/build/util/fusermount3 "$BUILD_DIR/system/bin/"
chmod 0755 "$BUILD_DIR"/system/bin/*

# 修改 module.prop 中的 updateJson 字段
UPDATE_JSON_URL="https://github.com/$REPO/releases/latest/download/update-$ABI.json"
sed -i "s|^updateJson=.*|updateJson=$UPDATE_JSON_URL|" "$BUILD_DIR/module.prop"

# 生成对应的 update.json 文件
cat <<EOF > update-$ABI.json
{
  "version": "$RCLONE_VERSION",
  "versionCode": $VERSION_CODE,
  "zipUrl": "https://github.com/$REPO/releases/download/$TAG_NAME/${MODULE_DIR}_$ABI.zip",
  "changelog": "https://github.com/$REPO/releases/tag/$TAG_NAME"
}
EOF

echo "生成的 update.json 文件: update-$ABI.json"

# 打包 ZIP 文件
cd "$BUILD_DIR"

# 双兼容：保留 Magisk 安装器，KernelSU 会忽略 META-INF/ 并走自己的安装流程
# （ksud 以 `unzip -x 'META-INF/*'` 解包，且本 zip 没有 install.sh，不会走 legacy 分支）。
mkdir -p META-INF/com/google/android
echo "#MAGISK" > META-INF/com/google/android/updater-script
wget -q https://raw.githubusercontent.com/topjohnwu/Magisk/refs/heads/master/scripts/module_installer.sh \
  -O META-INF/com/google/android/update-binary
chmod 0755 META-INF/com/google/android/update-binary

# zip 根目录必须直接包含 module.prop
ZIP_NAME="${MODULE_DIR}_$ABI.zip"
rm -f "../$ZIP_NAME"
zip -r9 "../$ZIP_NAME" . -x '.git*'
cd ..

echo "打包完成: $ZIP_NAME"
