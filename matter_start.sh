#!/bin/bash

#===== CONFIGURATION =====

# 持久化存储目录（重启后数据不丢失）
MATTER_DATA_DIR="/home/ubuntu/.matter-data"
THREAD_DATASET_FILE="$MATTER_DATA_DIR/thread_dataset.txt"
THREAD_NETWORK_NAME_FILE="$MATTER_DATA_DIR/thread_network_name.txt"
CHIP_STORAGE_DIR_BASE="$MATTER_DATA_DIR/chip-storage"
CHIP_STORAGE_DIR="$CHIP_STORAGE_DIR_BASE"
SCRIPT_VERSION="v4.05.382"

# 显示帮助信息
show_help() {
    cat << EOF
Usage: $0 <pin_code> <discriminator> [nodeid] <protocol> [options]

Arguments:
  pin_code        Matter PIN code (required)
  discriminator   Matter discriminator (required)
  nodeid          Matter node ID (optional, auto-generated if omitted)
  protocol        Network protocol: 'wifi' or 'thread' (required)

Options for wifi protocol:
  --ssid <ssid>               WiFi SSID (required for wifi)
  --password <password>       WiFi password (required for wifi)

Options for thread protocol:
  --force-create-threadnetwork    Force create new Thread network
  --use-thread-network <dataset>  Use specific Thread dataset
  --thread-set-channel <channel>  Thread channel to use when creating network (default: random 11-26)

Common options:
  --clear-cache               Clear cache before configuration (clears SRP, OTBR, chip, bluetooth)
  --help, -h                  Show this help message

Examples:
  # Auto-generate node ID
  $0 12345678 3840 thread
  
  # WiFi mode with specific node ID
  $0 12345678 3840 1 wifi --ssid MyWiFi --password MyPassword
  
  # Thread mode with specific node ID
  $0 12345678 3840 1 thread
  
  # Thread mode (force create)
  $0 12345678 3840 1 thread --force-create-threadnetwork
  
  # Thread mode (use specific dataset)
  $0 12345678 3840 1 thread --use-thread-network "0e08000000000001..."

EOF
    exit 0
}

# 清理缓存函数
clear_cache() {
    echo ""
    echo "===== CLEARING CACHE ====="
    
    # 重启 SRP server
    echo "🔄 Restarting SRP server..."
    sudo ot-ctl srp server disable
    sleep 2
    sudo ot-ctl srp server enable
    echo "✓ SRP server restarted"
    
    # 重启 otbr-agent
    echo "🔄 Restarting otbr-agent..."
    sudo systemctl restart otbr-agent
    # 等待 otbr-agent socket 就绪
    for i in $(seq 1 15); do
        if sudo ot-ctl state &>/dev/null; then
            break
        fi
        sleep 1
    done
    echo "✓ otbr-agent restarted"
    
    # 清理 chip-tool 缓存文件
    echo "🗑 Cleaning chip-tool cache..."
    sudo rm -rf /tmp/chip_*
    sudo rm -rf /tmp/repl-storage.json
    echo "✓ chip-tool cache cleaned"
    
    # 重启 avahi-daemon
    echo "🔄 Restarting avahi-daemon..."
    sudo systemctl restart avahi-daemon
    echo "✓ avahi-daemon restarted"

    # 清理持久化 Matter 数据
    echo "🗑 Cleaning persistent Matter data..."
    sudo rm -rf -R "$CHIP_STORAGE_DIR_BASE"
    sudo rm -f "$THREAD_DATASET_FILE"
    sudo rm -f "$THREAD_NETWORK_NAME_FILE"
    sudo mkdir -p "$CHIP_STORAGE_DIR_BASE"
    echo "✓ Persistent Matter data cleaned"

    echo "✓✓ Cache cleared successfully!"
    echo "================================"
}

# 初始化变量
PIN_CODE=""
DISCRIMINATOR=""
NODEID=""
PROTOCOL=""
SSID=""
PWD=""
FORCE_CREATE=false
USE_DATASET=""
THREAD_CHANNEL=""
CLEAR_CACHE=false
AUTO_YES=false

# 解析位置参数（至少 pin_code, discriminator, protocol 3个必需参数）
if [ $# -lt 3 ]; then
    echo "Error: Missing required arguments"
    show_help
fi

PIN_CODE=$1
DISCRIMINATOR=$2

# 判断第3个参数是否是数字（nodeid）还是协议名
if [[ "$3" =~ ^[0-9]+$ ]]; then
    # 第3个参数是数字 → 当做 nodeid
    NODEID=$3
    PROTOCOL=$4
    shift 4
else
    # 第3个参数不是数字 → 当做 protocol，nodeid 待自动生成
    NODEID=""
    PROTOCOL=$3
    shift 3
fi

# 解析可选参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            ;;
        --clear-cache)
            CLEAR_CACHE=true
            shift
            ;;
        -y|--yes)
            AUTO_YES=true
            shift
            ;;
        --ssid)
            SSID="$2"
            shift 2
            ;;
        --password)
            PWD="$2"
            shift 2
            ;;
        --force-create-threadnetwork)
            FORCE_CREATE=true
            shift
            ;;
        --use-thread-network)
            USE_DATASET="$2"
            shift 2
            ;;
        --thread-set-channel)
            THREAD_CHANNEL="$2"
            shift 2
            ;;
        *)
            echo "Error: Unknown option: $1"
            show_help
            ;;
    esac
done

# 自动生成 nodeid（如果未指定）
if [ -z "$NODEID" ]; then
    echo "🔍 Node ID not specified, generating random value (1 ~ 0xFFFF_FFEF_FFFF_FFFF)..."

    # 收集已存在的 nodeid
    declare -A existing_nodes
    if [ -d "$CHIP_STORAGE_DIR_BASE" ]; then
        for dir in "$CHIP_STORAGE_DIR_BASE"/node_*; do
            if [ -d "$dir" ]; then
                num="${dir##*/node_}"
                if [[ "$num" =~ ^[0-9]+$ ]]; then
                    existing_nodes["$num"]=1
                fi
            fi
        done
    fi

    # 生成不重复的随机 nodeid（1 ~ 0xFFFF_FFEF_FFFF_FFFF）
    while true; do
        NODEID=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
        python3 -c "v=$NODEID; exit(0 if 1 <= v <= 0xFFFF_FFEF_FFFF_FFFF else 1)" 2>/dev/null || continue
        if [ -z "${existing_nodes[$NODEID]}" ]; then
            break
        fi
    done
    echo "  → Assigned Node ID: $NODEID"
fi

CHIP_STORAGE_DIR="${CHIP_STORAGE_DIR_BASE}/node_${NODEID}"

# 验证参数
if [ -z "$PIN_CODE" ] || [ -z "$DISCRIMINATOR" ] || [ -z "$NODEID" ] || [ -z "$PROTOCOL" ]; then
    echo "Error: Missing required parameters"
    show_help
fi

# 验证协议
if [ "$PROTOCOL" != "wifi" ] && [ "$PROTOCOL" != "thread" ]; then
    echo "Error: Protocol must be 'wifi' or 'thread'"
    exit 1
fi

# WiFi 模式验证
if [ "$PROTOCOL" = "wifi" ]; then
    if [ -z "$SSID" ] || [ -z "$PWD" ]; then
        echo "Error: WiFi protocol requires --ssid and --password options"
        show_help
    fi
fi

# Thread 模式验证
if [ "$PROTOCOL" = "thread" ]; then
    if [ "$FORCE_CREATE" = true ] && [ -n "$USE_DATASET" ]; then
        echo "Error: Cannot use both --force-create-threadnetwork and --use-thread-network"
        exit 1
    fi
    # 提前解析 channel，使配置信息打印实际值
    if [ -z "$THREAD_CHANNEL" ] && [ -z "$USE_DATASET" ]; then
        THREAD_CHANNEL=$(( ( RANDOM % 16 ) + 11 ))
    fi
fi

echo "=========================================="
echo "Matter Device Configuration"
echo "=========================================="
echo "Script Version: $SCRIPT_VERSION"
echo "PIN Code:      $PIN_CODE"
echo "Discriminator: $DISCRIMINATOR"
echo "Node ID:       $NODEID"
echo "Protocol:      $PROTOCOL"
if [ "$PROTOCOL" = "wifi" ]; then
    echo "WiFi SSID:     $SSID"
    echo "WiFi Password: ***hidden***"
fi
if [ "$PROTOCOL" = "thread" ]; then
    echo "Force Create:  $FORCE_CREATE"
    if [ -n "$USE_DATASET" ]; then
        echo "Using Dataset: ${USE_DATASET:0:32}..."
    fi
fi
echo "Clear Cache:   $CLEAR_CACHE"
echo "=========================================="

#=========================

# 如果指定了 --clear-cache，执行清理
if [ "$CLEAR_CACHE" = true ]; then
    clear_cache
fi

# 检查并启动 cpcd
if systemctl is-active --quiet "cpcd"; then
    echo "✓ cpcd is running"
else
    echo "===== START CPCd ====="
    sudo systemctl start cpcd
    if systemctl is-active --quiet "cpcd"; then
        echo "✓ cpcd started successfully"
    else
        echo "✗ Failed to start cpcd"
        sudo systemctl status cpcd
        exit 1
    fi
fi

# Thread 模式处理
if [ "$PROTOCOL" = "thread" ]; then
    echo ""
    echo "===== OTBR Setup ====="
    
    # 检查 ot-ctl 是否可用
    if ! command -v ot-ctl &> /dev/null; then
        echo "✗ Error: ot-ctl not found! Please install OTBR first."
        exit 1
    fi
    
    dataset=""
    
    # 优先级1: 使用指定的 dataset
    if [ -n "$USE_DATASET" ]; then
        echo "📝 Using provided dataset..."
        dataset="$USE_DATASET"
        
        # 配置 Thread 网络
        echo "$USE_DATASET" | sudo ot-ctl dataset set active -x
        if [ $? -ne 0 ]; then
            echo "✗ Failed to set dataset"
            exit 1
        fi
        
        sudo ot-ctl dataset commit active
        sudo ot-ctl ifconfig up
        sudo ot-ctl thread start
        sleep 3
        
        # 验证配置
        verify_dataset=$(sudo ot-ctl dataset active -x 2>/dev/null | grep -o '[0-9a-fA-F]\+' | head -1)
        if [ "$verify_dataset" = "$USE_DATASET" ]; then
            echo "✓ Thread network configured with provided dataset"
        else
            echo "⚠ Warning: Applied dataset verification failed"
        fi

        # 保存到持久化存储
        echo "$dataset" | sudo tee "$THREAD_DATASET_FILE" > /dev/null
        echo "  Saved dataset to $THREAD_DATASET_FILE"

    # 优先级2: 强制创建新网络
    elif [ "$FORCE_CREATE" = true ]; then
        echo "🔄 Force creating new Thread network..."
        
    # 优先级3: 检查并使用现有网络
    else
        echo "🔍 Checking existing Thread network..."
        current_dataset=$(sudo ot-ctl dataset active -x 2>/dev/null | grep -o '[0-9a-fA-F]\+' | head -1)

        if [ -n "$current_dataset" ] && [ ${#current_dataset} -gt 10 ]; then
            echo "✓ Found existing Thread network"
            echo "  Dataset: ${current_dataset:0:32}..."
            if [ "$AUTO_YES" = true ]; then
                REPLY="y"
                echo "  Use existing network? (y/n): y  [auto]"
            else
                read -p "  Use existing network? (y/n): " -n 1 -r
                echo
            fi
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                # 检查 nodeid 是否已存在
                if [ -d "${CHIP_STORAGE_DIR_BASE}/node_${NODEID}" ]; then
                    echo ""
                    echo "✗ Error: Node ID $NODEID already exists (${CHIP_STORAGE_DIR_BASE}/node_${NODEID})"
                    echo "  This node appears to have been commissioned already."
                    echo "  Use a different Node ID or use --force-create-threadnetwork first."
                    exit 1
                fi
                dataset="$current_dataset"
                echo "✓ Using existing Thread network"
            else
                echo "  Will create new network"
            fi
        elif [ -f "$THREAD_DATASET_FILE" ]; then
            echo "  ot-ctl has no active dataset, restoring from persistent storage..."
            current_dataset=$(cat "$THREAD_DATASET_FILE")
            if [ -n "$current_dataset" ] && [ ${#current_dataset} -gt 10 ]; then
                echo "  Applying saved Thread dataset..."
                sudo ot-ctl thread stop
                sudo ot-ctl ifconfig down
                echo "$current_dataset" | sudo ot-ctl dataset set active -x
                sudo ot-ctl dataset commit active
                sudo ot-ctl ifconfig up
                sudo ot-ctl thread start
                sleep 3
                dataset="$current_dataset"
                echo "✓ Thread network restored from persistent storage"
            fi
        fi
    fi
    
    # 创建新网络（如果没有 dataset）
    if [ -z "$dataset" ]; then
        # 创建新网络前确保执行 clear-cache（若之前未执行过）
        if [ "$CLEAR_CACHE" = false ]; then
            clear_cache
            CLEAR_CACHE=true
        fi
        echo "🆕 Creating new Thread network..."
        
        # 检查 openssl
        if ! command -v openssl &> /dev/null; then
            echo "✗ Error: openssl not found! Installing..."
            sudo apt-get update && sudo apt-get install -y openssl
        fi
        
        # 生成随机值
        EXT_PAN_ID=$(openssl rand -hex 8)
        NETWORK_NAME="HomeNet-$(openssl rand -hex 3 | tr '[:lower:]' '[:upper:]')"
        MASTER_KEY=$(openssl rand -hex 16)
        PAN_ID=$(openssl rand -hex 2 | tr '[:lower:]' '[:upper:]')
        # 若未指定 channel，随机生成 11-26（已在参数验证阶段提前生成）
        if [ -z "$THREAD_CHANNEL" ]; then
            THREAD_CHANNEL=$(( ( RANDOM % 16 ) + 11 ))
        fi
        
        echo "  Generated parameters:"
        echo "    Extended PAN ID: $EXT_PAN_ID"
        echo "    Network Name:    $NETWORK_NAME"
        echo "    PAN ID:          $PAN_ID"
        echo "    Master Key:      ${MASTER_KEY:0:16}..."
        echo "    Channel:         $THREAD_CHANNEL"
        
        # 重置 Thread 栈，确保干净状态
        echo "  Resetting Thread stack..."
        sudo ot-ctl thread stop
        sudo ot-ctl ifconfig down
        sudo ot-ctl factoryreset
        sleep 3
        echo "  ✓ Thread stack reset"

        # 逐条执行 ot-ctl 命令配置 dataset
        echo "  Configuring dataset..."
        sudo ot-ctl dataset init new
        sudo ot-ctl dataset panid 0x$PAN_ID
        sudo ot-ctl dataset extpanid $EXT_PAN_ID
        sudo ot-ctl dataset networkname $NETWORK_NAME
        sudo ot-ctl dataset networkkey $MASTER_KEY
        sudo ot-ctl dataset channel $THREAD_CHANNEL
        if ! sudo ot-ctl dataset commit active; then
            echo "  ✗ Failed to configure dataset"
            exit 1
        fi
        echo "  ✓ Dataset configured"
        
        # 启动 Thread 网络
        sudo ot-ctl ifconfig up
        sudo ot-ctl thread start
        sleep 3
        
        # 获取生成的 dataset
        dataset=$(sudo ot-ctl dataset active -x 2>/dev/null | grep -o '[0-9a-fA-F]\+' | head -1)
        
        if [ -z "$dataset" ]; then
            echo "✗ Error: Failed to create Thread network!"
            exit 1
        fi
        
        echo "✓ Created new Thread network successfully!"
        echo "  Dataset: $dataset"
        echo "  Network Name: $NETWORK_NAME"
        
        # 保存到持久化存储
        echo "$dataset" | sudo tee "$THREAD_DATASET_FILE" > /dev/null
        echo "$NETWORK_NAME" | sudo tee "$THREAD_NETWORK_NAME_FILE" > /dev/null
        echo "  Saved to $THREAD_DATASET_FILE"
    fi
    
    if [ -z "$dataset" ]; then
        echo "✗ Error: No Thread dataset available!"
        exit 1
    fi
    
    echo ""
    echo "✓ Using Thread dataset: ${dataset:0:64}..."
fi

echo ""
echo "====== START NETWORK CONFIGURATION ======"

# 配置 chip-tool 路径
CHIP_TOOL_PATH=/home/ubuntu/apps/chip-tool
CERT_PATH=/var/paa-root-certs/
# 创建持久化存储目录
sudo mkdir -p "$CHIP_STORAGE_DIR"

# 检查 chip-tool 是否存在
if [ ! -f "$CHIP_TOOL_PATH" ]; then
    echo "⚠ Warning: chip-tool not found at $CHIP_TOOL_PATH"
    # 尝试查找 chip-tool
    CHIP_TOOL_PATH=$(find /home/ubuntu -name "chip-tool" -type f 2>/dev/null | head -1)
    if [ -z "$CHIP_TOOL_PATH" ]; then
        echo "✗ Error: chip-tool not found!"
        exit 1
    fi
    echo "✓ Found chip-tool at $CHIP_TOOL_PATH"
fi

# 执行网络配置
case $PROTOCOL in
    "wifi")
        echo "Configuring WiFi network..."
        echo "  SSID: $SSID"
        net_config_cmd="sudo $CHIP_TOOL_PATH pairing ble-wifi $NODEID \"$SSID\" \"$PWD\" $PIN_CODE $DISCRIMINATOR --paa-trust-store-path $CERT_PATH --storage-directory $CHIP_STORAGE_DIR"
        ;;
    "thread")
        echo "Configuring Thread network..."
        net_config_cmd="sudo $CHIP_TOOL_PATH pairing ble-thread $NODEID hex:$dataset $PIN_CODE $DISCRIMINATOR --paa-trust-store-path $CERT_PATH --storage-directory $CHIP_STORAGE_DIR"
        ;;
    *)
        echo "✗ Error: Unsupported protocol '$PROTOCOL'"
        exit 1
        ;;
esac

echo ""
echo "Executing command..."
echo "=========================================="
echo "$net_config_cmd"
eval $net_config_cmd
result=$?
echo "=========================================="

echo ""
echo "Node ID       :  $(printf "%-20s" "$NODEID (0x$(printf '%x' "$NODEID" | tr 'a-f' 'A-F'))")"
echo "Protocol      :  $(printf "%-20s" "$PROTOCOL")"
echo "PIN Code      :  $(printf "%-20s" "$PIN_CODE")"
echo "Discriminator :  $(printf "%-20s" "$DISCRIMINATOR")"
echo "Storage Dir   :  $(printf "%-20s" "$CHIP_STORAGE_DIR")"

if [ $result -eq 0 ]; then
    echo ""
    echo "✓✓✓ Network configuration completed successfully! ✓✓✓"
    exit 0
else
    echo ""
    echo "✗✗✗ Error: Network configuration failed! (exit code: $result) ✗✗✗"
    exit 1
fi
