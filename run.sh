#!/bin/bash

#  WES Tumor Analysis Pipeline

set -euo pipefail

echo " Запуск WES Tumor Analysis Pipeline"

# Настройки по умолчанию
REF_DIR="${REF_DIR:-./reference_ngs}"
PATIENTS_DIR="${PATIENTS_DIR:-./patients}"
VEP_CACHE_DIR="${VEP_CACHE_DIR:-./vep_cache}"

# Проверка Docker
check_docker() {
    echo " Проверка Docker..."
    if ! command -v docker &> /dev/null; then
        echo " ОШИБКА: Docker не установлен"
        echo ""
        echo "Как установить Docker:"
        echo "  Ubuntu: sudo apt install docker.io"
        echo "  CentOS: sudo yum install docker"
        echo "  macOS: https://docs.docker.com/desktop/install/mac-install/"
        echo ""
        exit 1
    fi
    
    if ! docker info &> /dev/null; then
        echo " Docker не запущен"
        echo "  Запустите Docker Desktop или выполните:"
        echo "  sudo systemctl start docker"
        exit 1
    fi
    echo " Docker проверен"
}

# Проверка референсных файлов
check_references() {
    echo ""
    echo " Проверка референсных файлов..."
    
    if [ ! -d "$REF_DIR" ]; then
        echo " Папка с референсами не найдена: $REF_DIR"
        echo ""
        echo "Сначала выполните:"
        echo "  mkdir -p $REF_DIR"
        echo "  # И скачайте референсные файлы"
        echo "  # Смотрите инструкцию в README.md"
        exit 1
    fi
    
    # Проверка основных файлов
    local missing_files=()
    
    [ ! -f "$REF_DIR/hg38.fa" ] && missing_files+=("hg38.fa")
    [ ! -f "$REF_DIR/Homo_sapiens_assembly38.dbsnp138.vcf.gz" ] && missing_files+=("dbSNP")
    [ ! -f "$REF_DIR/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz" ] && missing_files+=("Indels")
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo " Не найдены файлы: ${missing_files[*]}"
        echo ""
        echo "Скачайте референсные файлы:"
        echo "  ./download_references.sh"
        exit 1
    fi
    
    echo " Референсные файлы проверены"
}

# Создание папок
create_directories() {
    echo ""
    echo " Создание рабочих папок..."
    mkdir -p "$PATIENTS_DIR" "$VEP_CACHE_DIR"
    echo " Папки созданы:"
    echo "   - $REF_DIR"
    echo "   - $PATIENTS_DIR"
    echo "   - $VEP_CACHE_DIR"
}

# Построение Docker образа
build_docker_image() {
    echo " Построение Docker образа..."
    echo "   (Это займет 15-30 минут в первый раз)"
    
    docker build -t wes-tumor-pipeline .
    
    if [ $? -ne 0 ]; then
        echo " Ошибка при построении Docker образа"
        exit 1
    fi
    echo " Docker образ построен: wes-tumor-pipeline"
}

# Запуск пайплайна
run_pipeline() {
    echo ""
    echo " Запуск анализа..."
    
    # Подсчет пациентов
    local patient_count=0
    if [ -d "$PATIENTS_DIR" ]; then
        patient_count=$(find "$PATIENTS_DIR" -maxdepth 1 -type d | wc -l)
        patient_count=$((patient_count - 1))
    fi
    
    if [ $patient_count -eq 0 ]; then
        echo "  В папке patients нет данных пациентов"
        echo ""
        echo "Положите FASTQ файлы в папку:"
        echo "  $PATIENTS_DIR/patient_id/"
        echo "  $PATIENTS_DIR/patient_id/tumor_1.fastq.gz"
        echo "  $PATIENTS_DIR/patient_id/tumor_2.fastq.gz"
        exit 1
    fi
    
    echo " Найдено пациентов: $patient_count"
    echo ""
    
    # Определение количества ядер и памяти
    local cpu_count=$(nproc)
    local memory="32g"
    
    echo "  Параметры запуска:"
    echo "   CPU: $cpu_count ядер"
    echo "   RAM: $memory"
    echo ""
    
    # Запуск контейнера
    docker run --rm \
        -v "$(pwd)/$REF_DIR:/data/reference_ngs" \
        -v "$(pwd)/$PATIENTS_DIR:/data/patients" \
        -v "$(pwd)/$VEP_CACHE_DIR:/opt/vep/cache" \
        -v /tmp:/tmp \
        --memory="$memory" \
        --cpus="$cpu_count" \
        wes-tumor-pipeline \
        main_analis2.sh
    
    echo ""
}

# Показать результаты
show_results() {
    echo " Результаты анализа:"
    echo ""
    
    # Поиск результатов
    for patient_dir in "$PATIENTS_DIR"/*/; do
        if [ -d "$patient_dir" ]; then
            patient=$(basename "$patient_dir")
            echo " Пациент: $patient"
            
            if [ -d "$patient_dir/reports" ]; then
                echo "    Отчеты:"
                [ -f "$patient_dir/reports/${patient}_extended_annotations.tsv" ] && \
                    echo "     - extended_annotations.tsv"
                [ -f "$patient_dir/reports/${patient}_significant_mutations.tsv" ] && \
                    echo "     - significant_mutations.tsv"
                [ -f "$patient_dir/reports/${patient}_high_impact.tsv" ] && \
                    echo "     - high_impact.tsv"
                [ -f "$patient_dir/reports/${patient}_variant_summary.txt" ] && \
                    echo "     - variant_summary.txt"
            else
                echo "Отчеты не сгенерированы"
            fi
            echo ""
        fi
    done
    
    echo " Анализ завершен успешно"
}

# Главная функция
main() {
    check_docker
    check_references
    create_directories
    build_docker_image
    run_pipeline
    show_results
}

# Запуск
main "$@"