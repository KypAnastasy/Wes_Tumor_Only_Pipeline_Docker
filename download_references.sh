#!/bin/bash

#  WES Pipeline: Скачивание референсов

set -euo pipefail

echo " Скачивание референсных файлов"

# Настройки
REF_DIR="${REF_DIR:-./reference_ngs}"
THREADS=${THREADS:-4}

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функции
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка места на диске
check_disk_space() {
    local required_gb=30
    local available_gb=$(df -BG . | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [ "$available_gb" -lt "$required_gb" ]; then
        print_warn "Мало свободного места: ${available_gb}GB"
        print_warn "Требуется минимум: ${required_gb}GB"
        read -p "Продолжить? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

# Создание директории
create_ref_dir() {
    mkdir -p "$REF_DIR"
    cd "$REF_DIR"
    print_info "Рабочая директория: $(pwd)"
}

# Скачивание hg38
download_hg38() {
    print_info "1. Скачивание hg38 референсного генома..."
    
    if [ -f "hg38.fa" ]; then
        print_warn "hg38.fa уже существует, пропустить"
        return 0
    fi
    
    # Скачиваение файла по частям
    wget -c http://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz \
        || wget -c https://hgdownload.soe.ucsc.edu/goldenPath/hg38/bigZips/hg38.fa.gz
    
    if [ $? -eq 0 ] && [ -f "hg38.fa.gz" ]; then
        print_info "Распаковка hg38.fa.gz..."
        gunzip hg38.fa.gz
        print_info " hg38 скачан: $(du -sh hg38.fa)"
    else
        print_error "Не удалось скачать hg38"
        return 1
    fi
}

# Скачивание dbSNP
download_dbsnp() {
    print_info "2. Скачивание dbSNP v138..."
    
    if [ -f "Homo_sapiens_assembly38.dbsnp138.vcf.gz" ]; then
        print_warn "dbSNP уже существует, пропустить"
        return 0
    fi
    
    wget -c https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Homo_sapiens_assembly38.dbsnp138.vcf
    
    if [ $? -eq 0 ] && [ -f "Homo_sapiens_assembly38.dbsnp138.vcf" ]; then
        print_info "Сжатие dbSNP..."
        bgzip Homo_sapiens_assembly38.dbsnp138.vcf
        print_info "Индексация dbSNP..."
        tabix Homo_sapiens_assembly38.dbsnp138.vcf.gz
        print_info " dbSNP готов"
    fi
}

# Скачивание инделов
download_indels() {
    print_info "3. Скачивание инделов..."
    
    if [ -f "Mills_and_1000G_gold_standard.indels.hg38.vcf.gz" ]; then
        print_warn "Инделы уже существуют, пропустить"
        return 0
    fi
    
    wget -c https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz
    tabix Mills_and_1000G_gold_standard.indels.hg38.vcf.gz
    print_info " Инделы готовы"
}

# Скачивание gnomAD
download_gnomad() {
    print_info "4. Скачивание gnomAD..."
    
    if [ -f "af-only-gnomad.hg38.vcf.gz" ]; then
        print_warn "gnomAD уже существует, пропустить"
        return 0
    fi
    
    wget -c https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/af-only-gnomad.hg38.vcf.gz
    tabix af-only-gnomad.hg38.vcf.gz
    print_info " gnomAD готов"
}

# Скачивание Panel of Normals
download_pon() {
    print_info "5. Скачивание Panel of Normals..."
    
    if [ -f "1000g_pon.hg38.vcf.gz" ]; then
        print_warn "Panel of Normals уже существует, пропустить"
        return 0
    fi
    
    wget -c https://storage.googleapis.com/genomics-public-data/resources/broad/hg38/v0/1000g_pon.hg38.vcf.gz
    tabix 1000g_pon.hg38.vcf.gz
    print_info " Panel of Normals готов"
}

# Создание индексов
create_indexes() {
    print_info "6. Создание индексов..."
    
    if [ ! -f "hg38.fa" ]; then
        print_error "hg38.fa не найден"
        return 1
    fi
    
    # Индекс для samtools
    if [ ! -f "hg38.fa.fai" ]; then
        print_info "Создание индекса для samtools..."
        samtools faidx hg38.fa
    fi
    
    # Словарь для GATK
    if [ ! -f "hg38.dict" ]; then
        print_info "Создание словаря для GATK..."
        gatk CreateSequenceDictionary -R hg38.fa -O hg38.dict 2>/dev/null || \
        echo "  Не удалось создать словарь  "
    fi
    
    # Индекс для BWA-MEM2 
    print_info "Индекс для BWA-MEM2 будет создан автоматически при первом запуске"
    
    print_info " Индексы созданы"
}

# Файл с генами рака груди
create_gene_list() {
    print_info "7. Создание списка генов рака груди..."
    
    cat > breast_cancer_genes.txt << 'EOF'
BRCA1
BRCA2
TP53
PTEN
PIK3CA
AKT1
ESR1
ERBB2
CDH1
STK11
PALB2
CHEK2
ATM
BRIP1
EOF
    
    print_info " Список генов создан"
}

# Сводка
show_summary() {
    echo " Сводка скачанных файлов"
    
    local total_size=0
    local file_count=0
    
    for file in *; do
        if [ -f "$file" ]; then
            size=$(du -sh "$file" | cut -f1)
            echo "  $size - $file"
            file_count=$((file_count + 1))
        fi
    done
    
    echo ""
    echo " Всего файлов: $file_count"
    echo " Общий размер: $(du -sh . | cut -f1)"
    echo ""
    echo " Референсные файлы готовы к использованию"
    echo ""
    echo "Можно совершить запуск анализа:"
    echo "  ./run.sh"
    echo ""
}

# Главная функция
main() {
    print_info "Начало загрузки референсных файлов"
    print_warn "ВНИМАНИЕ: Это займет 30-40 ГБ места"
    print_warn "         и несколько часов времени"
    echo ""
    
    if [ "${AUTO:-0}" != "1" ]; then
        read -p "Продолжить загрузку? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    fi
    
    check_disk_space
    create_ref_dir
    
    # Скачивание файлов
    download_hg38
    download_dbsnp
    download_indels
    download_gnomad
    download_pon
    
    # Создание индексов и списка генов
    create_indexes
    create_gene_list
    
    show_summary
}

# Запуск
main "$@"