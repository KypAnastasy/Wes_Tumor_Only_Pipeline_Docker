#!/bin/bash

# Загрузка конфигурацит
if [ -f /data/pipeline.config ]; then
    source /data/pipeline.config
    echo "Конфигурация загружена из /data/pipeline.config"
elif [ -f /usr/local/bin/pipeline.config.example ]; then
    echo "Внимание: файл конфигурации /data/pipeline.config не найден. Используются значения по умолчанию."
fi

# Устанавливка значения по умолчанию, если не заданы в конфиге
REFERENCE_DIR="${REFERENCE_DIR:-/data/reference_ngs}"
PATIENTS_DIR="${PATIENTS_DIR:-/data/patients}"
SNPEFF_DB="${SNPEFF_DB:-GRCh38.86}"
NUM_THREADS="${NUM_THREADS:-4}"
VEP_CACHE="${VEP_CACHE:-/opt/vep/cache}"

# Настройки
set -euo pipefail

# Проверка существования папки с пациентами
if [ ! -d "$PATIENTS_DIR" ]; then
  echo "Ошибка: Папка с пациентами не найдена: $PATIENTS_DIR"
  exit 1
fi

# Проверка существования папки с референсами
if [ ! -d "$REFERENCE_DIR" ]; then
  echo "Ошибка: Папка с референсами не найдена: $REFERENCE_DIR"
  exit 1
fi

# Функция для проверки доступности программы
check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "Ошибка: Команда $1 не найдена. Установите её и добавьте в PATH."
    exit 1
  fi
}

# Проверка необходимых команд
for cmd in fastq-dump fastqc fastp bwa-mem2 gatk samtools vep snpEff; do
  check_command "$cmd"
done

# Проверка Python3
if ! command -v python3 &> /dev/null; then
  echo "Ошибка: Python3 не найден. Установите его."
  exit 1
fi

for cmd in bcftools bgzip tabix; do
  check_command "$cmd"
done

# Функции автоматической загрузки данных
check_references() {
    echo "Проверка референсных файлов..."
    local missing=0
    local files=(
        "$REFERENCE_DIR/hg38.fa"
        "$REFERENCE_DIR/Homo_sapiens_assembly38.dbsnp138.vcf.gz"
        "$REFERENCE_DIR/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"
        "$REFERENCE_DIR/af-only-gnomad.hg38.vcf.gz"
        "$REFERENCE_DIR/1000g_pon.hg38.vcf.gz"
    )
    for file in "${files[@]}"; do
        if [ ! -f "$file" ] && [ ! -f "$(echo "$file" | sed 's/.gz$//')" ]; then
            echo "  Не найден: $(basename "$file")"
            missing=1
        fi
    done
    if [ $missing -eq 1 ]; then
        echo "Некоторые референсные файлы отсутствуют. Запуск загрузки..."
        AUTO=1 /usr/local/bin/download_references.sh
        if [ $? -ne 0 ]; then
            echo "Ошибка загрузки референсных файлов. Пожалуйста, проверьте интернет и свободное место."
            exit 1
        fi
    else
        echo "Все референсные файлы имеются."
    fi
}

check_snpeff_db() {
    echo "Проверка базы SnpEff ($SNPEFF_DB)..."
    # Проверка наличие базы в стандартных местах
    if [ ! -d "/usr/share/snpeff/data/$SNPEFF_DB" ] && [ ! -d "/opt/snpEff/data/$SNPEFF_DB" ]; then
        echo "База SnpEff $SNPEFF_DB не найдена. Скачивание (это займёт некоторое время)..."
        snpEff download "$SNPEFF_DB"
        if [ $? -ne 0 ]; then
            echo "Ошибка загрузки базы SnpEff. Проверьте интернет."
            exit 1
        fi
    else
        echo "База SnpEff $SNPEFF_DB уже установлена."
    fi
}

check_vep_cache() {
    echo "Проверка VEP cache..."
    if [ ! -d "$VEP_CACHE/homo_sapiens" ]; then
        echo "VEP cache не найден в $VEP_CACHE. Установка (это займёт несколько минут)..."
        perl /opt/vep/INSTALL.pl -a c -s homo_sapiens -y GRCh38 -c "$VEP_CACHE"
        if [ $? -ne 0 ]; then
            echo "Ошибка установки VEP cache. Попробуйте установить вручную."
            exit 1
        fi
    else
        echo "VEP cache найден."
    fi
}

# Логирование
LOG_FILE="$PATIENTS_DIR/pipeline_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Начало выполнения пайплайна: $(date)"
echo "Используются базовые аннотации SnpEff и VEP без внешних баз данных"

# Автоматическая загрузка недостающих данных
check_references
check_snpeff_db
check_vep_cache

# Создание списка референсных файлов
REFERENCE_GENOME="$REFERENCE_DIR/hg38.fa"
DBSNP="$REFERENCE_DIR/Homo_sapiens_assembly38.dbsnp138.vcf.gz"
INDELS="$REFERENCE_DIR/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz"
GNOMAD="$REFERENCE_DIR/af-only-gnomad.hg38.vcf.gz"
SMALL_EXAC="$REFERENCE_DIR/af-only-gnomad.hg38.vcf.gz"  # используется в GetPileupSummaries

# Проверка существования референсных файлов (повторная, после загрузки)
for file in "$REFERENCE_GENOME" "$DBSNP" "$INDELS" "$GNOMAD" "$SMALL_EXAC"; do
  if [ ! -f "$file" ] && [ ! -f "$(echo "$file" | sed 's/.gz$//')" ]; then
    echo "Внимание: Референсный файл не найден: $(basename "$file")"
  fi
done

# Создание списка генов рака груди (если еще не существует)
BREAST_CANCER_GENES="$REFERENCE_DIR/breast_cancer_genes.txt"
if [ ! -f "$BREAST_CANCER_GENES" ]; then
    echo "Создание списка генов рака груди..."
    cat > "$BREAST_CANCER_GENES" << 'EOF'
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
fi

# Функция для создания отчета из объединенных аннотаций
create_extended_report() {
  local input_vcf="$1"
  local output_tsv="$2"
  
  echo "Создание расширенного отчета из объединенных аннотаций..."
  
  # Создание временного файла с данными
  bcftools query -f '%CHROM\t%POS\t%REF\t%ALT\t%INFO/CSQ\t%INFO/ANN\n' \
    "$input_vcf" 2>/dev/null > "${output_tsv}.tmp"
  
  # Использование Python для парсинга объединенных данных
  python3 -c "
import sys

def parse_vep_csq(csq_string):
    '''Парсинг CSQ аннотаций VEP'''
    if not csq_string or csq_string == '.':
        return {}
    
    # Взятие первой (канонической) аннотацию
    first_csq = csq_string.split(',')[0]
    fields = first_csq.split('|')
    
    # Стандартные поля VEP CSQ (базовая версия)
    vep_fields = [
        'Allele', 'Consequence', 'IMPACT', 'SYMBOL', 'Gene', 'Feature_type',
        'Feature', 'BIOTYPE', 'EXON', 'INTRON', 'HGVSc', 'HGVSp',
        'cDNA_position', 'CDS_position', 'Protein_position', 'Amino_acids',
        'Codons', 'Existing_variation', 'DISTANCE', 'STRAND', 'FLAGS',
        'SYMBOL_SOURCE', 'CANONICAL'
    ]
    
    result = {}
    for i, field in enumerate(vep_fields):
        if i < len(fields):
            result[field] = fields[i]
        else:
            result[field] = '.'
    return result

def parse_snpeff_ann(ann_string):
    '''Парсинг ANN аннотаций SnpEff'''
    if not ann_string or ann_string == '.':
        return {}
    
    # Взятие первой аннотации
    first_ann = ann_string.split(',')[0]
    fields = first_ann.split('|')
    
    # Поля SnpEff ANN
    ann_fields = [
        'Allele', 'Annotation', 'Annotation_Impact', 'Gene_Name', 'Gene_ID',
        'Feature_Type', 'Feature_ID', 'Transcript_BioType', 'Rank',
        'HGVS.c', 'HGVS.p', 'cDNA.pos', 'cDNA.length', 'CDS.pos', 'CDS.length',
        'AA.pos', 'AA.length', 'Distance', 'Errors'
    ]
    
    result = {}
    for i, field in enumerate(ann_fields):
        if i < len(fields):
            result[field] = fields[i]
        else:
            result[field] = '.'
    return result

def main():
    input_file = '${output_tsv}.tmp'
    output_file = '${output_tsv}'
    
    with open(input_file, 'r') as f, open(output_file, 'w') as out:
        # Заголовок отчета
        header = [
            'Хромосома', 'Позиция', 'REF', 'ALT', 'Ген', 'Тип_мутации', 'IMPACT',
            'Изменение_белка', 'Транскрипт', 'Биотип', 'Экзон/Интрон',
            'Позиция_кДНК', 'Позиция_CDS', 'Позиция_белка', 'Аминокислоты',
            'Кодоны', 'Существующий_вариант', 'Расстояние', 'Странд', 'Канонический',
            'Дополнительно_SnpEff', 'Дополнительно_VEP'
        ]
        out.write('\t'.join(header) + '\\n')
        
        count = 0
        for line in f:
            if not line.strip():
                continue
                
            parts = line.strip().split('\\t')
            if len(parts) < 6:
                continue
                
            chrom, pos, ref, alt, csq, ann = parts[:6]
            
            # Парсинг аннотации
            vep_data = parse_vep_csq(csq)
            snpeff_data = parse_snpeff_ann(ann)
            
            # Объединение данных 
            gene = vep_data.get('SYMBOL', snpeff_data.get('Gene_Name', '.'))
            consequence = vep_data.get('Consequence', snpeff_data.get('Annotation', '.'))
            impact = vep_data.get('IMPACT', snpeff_data.get('Annotation_Impact', '.'))
            protein_change = vep_data.get('HGVSp', snpeff_data.get('HGVS.p', '.'))
            transcript = vep_data.get('Feature', snpeff_data.get('Feature_ID', '.'))
            biotype = vep_data.get('BIOTYPE', snpeff_data.get('Transcript_BioType', '.'))
            
            # Экзон/интрон
            exon = vep_data.get('EXON', '.')
            intron = vep_data.get('INTRON', '.')
            exon_intron = '.'
            if exon != '.' and exon != '':
                exon_intron = f'экзон {exon}'
            elif intron != '.' and intron != '':
                exon_intron = f'интрон {intron}'
            
            # Позиции
            cdna_pos = vep_data.get('cDNA_position', snpeff_data.get('cDNA.pos', '.'))
            cds_pos = vep_data.get('CDS_position', snpeff_data.get('CDS.pos', '.'))
            protein_pos = vep_data.get('Protein_position', snpeff_data.get('AA.pos', '.'))
            
            amino_acids = vep_data.get('Amino_acids', '.')
            codons = vep_data.get('Codons', '.')
            existing_variant = vep_data.get('Existing_variation', '.')
            distance = vep_data.get('DISTANCE', snpeff_data.get('Distance', '.'))
            strand = vep_data.get('STRAND', '.')
            canonical = vep_data.get('CANONICAL', '.')
            
            # Дополнительная информация
            snpeff_extra = f'Gene_ID:{snpeff_data.get(\"Gene_ID\",\".\")}|Feature_Type:{snpeff_data.get(\"Feature_Type\",\".\")}|Rank:{snpeff_data.get(\"Rank\",\".\")}'
            vep_extra = f'Feature_type:{vep_data.get(\"Feature_type\",\".\")}|SYMBOL_SOURCE:{vep_data.get(\"SYMBOL_SOURCE\",\".\")}|FLAGS:{vep_data.get(\"FLAGS\",\".\")}'
            
            # Запись строки
            row = [
                chrom, pos, ref, alt, gene, consequence, impact,
                protein_change, transcript, biotype, exon_intron,
                cdna_pos, cds_pos, protein_pos, amino_acids,
                codons, existing_variant, distance, strand, canonical,
                snpeff_extra, vep_extra
            ]
            
            # Замена пустых значений
            row = [x if x and x != '' else '.' for x in row]
            out.write('\\t'.join(row) + '\\n')
            count += 1
    
    print(f'Создан отчет с {count} вариантами')

if __name__ == '__main__':
    main()
" && echo " Отчет создан" || echo " Ошибка при создании отчета Python"
  
  # Удаление временного файла
  rm -f "${output_tsv}.tmp"
}

# Перебор всех папок с пациентами
for PATIENT_DIR in "$PATIENTS_DIR"/*/; do
  # Проверяем, что это папка
  if [ ! -d "$PATIENT_DIR" ]; then
    continue
  fi

  # Получение ID пациента из имени папки
  PATIENT_ID=$(basename "$PATIENT_DIR")
  
  echo "Обработка пациента: $PATIENT_ID"
  echo "Время начала: $(date)"
  
  # Создание поддиректорий для результатов
  mkdir -p "$PATIENT_DIR/fastqc_reports" "$PATIENT_DIR/temp" "$PATIENT_DIR/reports"
  
  # 1. Поиск и конвертация SRA файлов
  echo "Шаг 1: Поиск SRA файлов..."
  SRA_FILES=("$PATIENT_DIR"/*.sra)
  
  if [ ${#SRA_FILES[@]} -eq 0 ]; then
    echo "SRA файлы не найдены. Пропуск конвертации."
  else
    for SRA_FILE in "${SRA_FILES[@]}"; do
      echo "Конвертация SRA в FASTQ: $(basename "$SRA_FILE")"
      fastq-dump --split-files --gzip "$SRA_FILE" -O "$PATIENT_DIR"
      if [ $? -ne 0 ]; then
        echo "Ошибка при конвертации SRA файла"
        continue
      fi
    done
  fi
  
  # 2. Поиск FASTQ файлов
  echo "Шаг 2: Поиск FASTQ файлов..."
  FASTQ1=$(find "$PATIENT_DIR" -name "*_1.fastq" -o -name "*_1.fastq.gz" | head -1)
  FASTQ2=$(find "$PATIENT_DIR" -name "*_2.fastq" -o -name "*_2.fastq.gz" | head -1)
  
  if [ -z "$FASTQ1" ] || [ -z "$FASTQ2" ]; then
    echo "Ошибка: Не найдены парные FASTQ файлы"
    continue
  fi
  
  echo "Найдены файлы:"
  echo "  FASTQ1: $(basename "$FASTQ1")"
  echo "  FASTQ2: $(basename "$FASTQ2")"
  
  # 3. Декомпрессия (если нужно)
  if [[ "$FASTQ1" == *.gz ]]; then
    echo "Декомпрессия FASTQ файлов..."
    gunzip -f "$FASTQ1" "$FASTQ2" 2>/dev/null || true
    FASTQ1="${FASTQ1%.gz}"
    FASTQ2="${FASTQ2%.gz}"
  fi
  
  # 4. QC (перед обрезкой)
  echo "Шаг 3: QC до обрезки..."
  fastqc "$FASTQ1" "$FASTQ2" -o "$PATIENT_DIR/fastqc_reports" --threads $NUM_THREADS
  
  # 5. Обрезка с помощью fastp
  echo "Шаг 4: Обрезка адаптеров..."
  fastp -i "$FASTQ1" -I "$FASTQ2" \
    -o "$PATIENT_DIR/${PATIENT_ID}_1.trim.fastq" -O "$PATIENT_DIR/${PATIENT_ID}_2.trim.fastq" \
    --detect_adapter_for_pe --trim_poly_g --cut_front --cut_tail --cut_mean_quality 20 \
    --length_required 30 --thread $NUM_THREADS \
    --html "$PATIENT_DIR/reports/fastp_report.html" \
    --json "$PATIENT_DIR/reports/fastp_report.json"
  
  # 6. QC (после обрезки)
  echo "Шаг 5: QC после обрезки..."
  fastqc "$PATIENT_DIR/${PATIENT_ID}_1.trim.fastq" "$PATIENT_DIR/${PATIENT_ID}_2.trim.fastq" \
    -o "$PATIENT_DIR/fastqc_reports" --threads $NUM_THREADS
  
  # 7. Выравнивание с BWA-MEM2
  echo "Шаг 6: Выравнивание с BWA-MEM2..."
  bwa-mem2 mem -t $NUM_THREADS -R "@RG\tID:$PATIENT_ID\tSM:$PATIENT_ID\tPL:ILLUMINA\tLB:lib1\tPU:unit1" \
    "$REFERENCE_GENOME" \
    "$PATIENT_DIR/${PATIENT_ID}_1.trim.fastq" \
    "$PATIENT_DIR/${PATIENT_ID}_2.trim.fastq" > "$PATIENT_DIR/${PATIENT_ID}.sam"
  
  # 8. Конвертация и сортировка BAM
  echo "Шаг 7: Сортировка BAM файла..."
  samtools view -@ $NUM_THREADS -bS "$PATIENT_DIR/${PATIENT_ID}.sam" | \
    samtools sort -@ $NUM_THREADS -o "$PATIENT_DIR/${PATIENT_ID}.sorted.bam"
  
  # Удаление временного SAM файла
  rm -f "$PATIENT_DIR/${PATIENT_ID}.sam"
  
  # 9. Индексация отсортированного BAM
  echo "Шаг 8: Индексация BAM файла..."
  samtools index "$PATIENT_DIR/${PATIENT_ID}.sorted.bam"
  
  # 10. Удаление дубликатов
  echo "Шаг 9: Удаление дубликатов..."
  gatk MarkDuplicates \
    -I "$PATIENT_DIR/${PATIENT_ID}.sorted.bam" \
    -O "$PATIENT_DIR/${PATIENT_ID}.dedup.bam" \
    -M "$PATIENT_DIR/reports/${PATIENT_ID}_duplicate_metrics.txt" \
    --CREATE_INDEX true
  
  # 11. Рекалибровка баз (BQSR)
  echo "Шаг 10: Рекалибровка баз..."
  
  # Создание таблицы рекалибровки
  gatk BaseRecalibrator \
    -I "$PATIENT_DIR/${PATIENT_ID}.dedup.bam" \
    -R "$REFERENCE_GENOME" \
    --known-sites "$DBSNP" \
    --known-sites "$INDELS" \
    -O "$PATIENT_DIR/reports/${PATIENT_ID}.recal.table" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  # Применение рекалибровки
  gatk ApplyBQSR \
    -R "$REFERENCE_GENOME" \
    -I "$PATIENT_DIR/${PATIENT_ID}.dedup.bam" \
    --bqsr-recal-file "$PATIENT_DIR/reports/${PATIENT_ID}.recal.table" \
    -O "$PATIENT_DIR/${PATIENT_ID}.recal.bam" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  # 12. Подготовка к анализу Mutect2
  echo "Шаг 11: Подготовка к анализу Mutect2..."
  
  # Для tumor-only анализа нужны дополнительные шаги
  gatk GetPileupSummaries \
    -I "$PATIENT_DIR"/${PATIENT_ID}.recal.bam \
    -V "$SMALL_EXAC" \
    -L chr1 -L chr2 -L chr3 -L chr4 -L chr5 -L chr6 -L chr7 -L chr8 -L chr9 -L chr10 \
    -L chr11 -L chr12 -L chr13 -L chr14 -L chr15 -L chr16 -L chr17 -L chr18 -L chr19 -L chr20 \
    -L chr21 -L chr22 -L chrX -L chrY \
    -O "$PATIENT_DIR/reports/${PATIENT_ID}.pileups.table" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  gatk CalculateContamination \
    -I "$PATIENT_DIR/reports/${PATIENT_ID}.pileups.table" \
    -O "$PATIENT_DIR/reports/${PATIENT_ID}.contamination.table" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  # 13. Вызов вариантов с Mutect2
  echo "Шаг 12: Вызов вариантов (Mutect2)..."
  
  gatk Mutect2 \
    -R "$REFERENCE_GENOME" \
    -I "$PATIENT_DIR/${PATIENT_ID}.recal.bam" \
    -tumor "$PATIENT_ID" \
    --germline-resource "$GNOMAD" \
    --panel-of-normals "$REFERENCE_DIR/1000g_pon.hg38.vcf.gz" \
    --f1r2-tar-gz "$PATIENT_DIR/reports/${PATIENT_ID}.f1r2.tar.gz" \
    -O "$PATIENT_DIR/${PATIENT_ID}.unfiltered.vcf.gz" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  # 14. Обучение модели ориентации ридов
  echo "Шаг 13: Обучение модели ориентации ридов..."
  gatk LearnReadOrientationModel \
    -I "$PATIENT_DIR/reports/${PATIENT_ID}.f1r2.tar.gz" \
    -O "$PATIENT_DIR/reports/${PATIENT_ID}.orientation.model.tar.gz"
  
  # 15. Фильтрация вариантов
  echo "Шаг 14: Фильтрация вариантов..."
  gatk FilterMutectCalls \
    -R "$REFERENCE_GENOME" \
    -V "$PATIENT_DIR/${PATIENT_ID}.unfiltered.vcf.gz" \
    --contamination-table "$PATIENT_DIR/reports/${PATIENT_ID}.contamination.table" \
    --ob-priors "$PATIENT_DIR/reports/${PATIENT_ID}.orientation.model.tar.gz" \
    -O "$PATIENT_DIR/${PATIENT_ID}.filtered.vcf.gz" \
    --tmp-dir "$PATIENT_DIR/temp"
  
  # 16. Извлечение прошедших фильтр вариантов
  echo "Шаг 15: Извлечение прошедших фильтр вариантов..."
  gatk SelectVariants \
    -R "$REFERENCE_GENOME" \
    -V "$PATIENT_DIR/${PATIENT_ID}.filtered.vcf.gz" \
    -O "$PATIENT_DIR/${PATIENT_ID}.passed.vcf.gz" \
    --exclude-filtered true
  
  # 17. Распаковка VCF для аннотации
  echo "Шаг 16: Подготовка файла для аннотации..."
  
  if [ ! -f "$PATIENT_DIR/${PATIENT_ID}.passed.vcf" ]; then
    echo "Распаковка passed.vcf.gz для аннотации..."
    gunzip -c "$PATIENT_DIR/${PATIENT_ID}.passed.vcf.gz" > "$PATIENT_DIR/${PATIENT_ID}.passed.vcf"
  fi
  
  # 18. Аннотация SnpEff (базовая, но богатая)
  echo "Шаг 17: Аннотация SnpEff..."
  
  # SnpEff с расширенными опциями
  snpEff -Xmx8G -i vcf -o vcf "$SNPEFF_DB" \
    -cancer \
    -canon \
    -no-downstream \
    -no-intergenic \
    -no-upstream \
    "$PATIENT_DIR/${PATIENT_ID}.passed.vcf" > \
    "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf"
  
  # Сжатие и индексирование результата SnpEff
  bgzip -f "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf"
  tabix -p vcf "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf.gz"
  
  # 19. Аннотация VEP 
  echo "Шаг 18: Аннотация VEP..."
  
  vep -i "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf.gz" \
    -o "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf" \
    --cache \
    --dir_cache "$VEP_CACHE" \
    --fasta "$REFERENCE_GENOME" \
    --offline \
    --species homo_sapiens \
    --assembly GRCh38 \
    --format vcf \
    --vcf \
    --symbol \
    --canonical \
    --hgvs \
    --protein \
    --terms SO \
    --pick \
    --pick_order canonical,tsl,biotype,rank,ccds,length \
    --show_ref_allele \
    --total_length \
    --no_escape \
    --allele_number \
    --regulatory \
    --mirna \
    --per_gene \
    --plugin Blosum62 \
    --plugin CSN \
    --plugin Downstream \
    --plugin NearestGene \
    --plugin SpliceRegion \
    --plugin TSSDistance \
    --plugin UTRAnnotator \
    --plugin MaxEntScan \
    --fork $NUM_THREADS \
    --force_overwrite
  
  # Проверка успешности выполнения
  if [ $? -eq 0 ] && [ -f "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf" ]; then
    echo "VEP аннотация успешно завершена"
    
    # Сжатие и индексирование финального VCF
    bgzip -f "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf"
    tabix -p vcf "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz"
  else
    echo "Ошибка при выполнении VEP. Используется только SnpEff..."
    # Копирование SnpEff результата как финальный
    cp "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf.gz" "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz"
    cp "$PATIENT_DIR/${PATIENT_ID}.snpeff.vcf.gz.tbi" "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz.tbi" 2>/dev/null || true
  fi
  
  # 20. Создание расширенного отчета
  echo "Шаг 19: Создание расширенных отчетов..."
  
  # Проверка, что файл существует
  if [ ! -f "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz" ]; then
    echo "Ошибка: Аннотированный VCF не найден"
    continue
  fi
  
  # Создание расширенного отчета через функцию
  create_extended_report \
    "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz" \
    "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv"
  
  # 21. Создание специфических отчетов
  echo "Шаг 20: Создание специфических отчетов..."
  
  # A. Все значимые мутации (с учетом IMPACT)
  if [ -s "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" ]; then
    # Значимые мутации (MODERATE и HIGH impact)
    head -n 1 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" > \
      "$PATIENT_DIR/reports/${PATIENT_ID}_significant_mutations.tsv"
    
    tail -n +2 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" | \
      awk -F'\t' '$7 == "HIGH" || $7 == "MODERATE"' >> \
      "$PATIENT_DIR/reports/${PATIENT_ID}_significant_mutations.tsv"
    
    SIGNIFICANT_COUNT=$(( $(wc -l < "$PATIENT_DIR/reports/${PATIENT_ID}_significant_mutations.tsv") - 1 ))
    echo "Значимые мутации (HIGH/MODERATE): $SIGNIFICANT_COUNT"
    
    # B. Только HIGH impact мутации
    head -n 1 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" > \
      "$PATIENT_DIR/reports/${PATIENT_ID}_high_impact.tsv"
    
    tail -n +2 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" | \
      awk -F'\t' '$7 == "HIGH"' >> \
      "$PATIENT_DIR/reports/${PATIENT_ID}_high_impact.tsv"
    
    HIGH_COUNT=$(( $(wc -l < "$PATIENT_DIR/reports/${PATIENT_ID}_high_impact.tsv") - 1 ))
    echo "HIGH impact мутации: $HIGH_COUNT"
    
    # C. Мутации в генах рака груди
    if [ -f "$BREAST_CANCER_GENES" ]; then
      head -n 1 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" > \
        "$PATIENT_DIR/reports/${PATIENT_ID}_breast_cancer.tsv"
      
      # Создание временного файла с генами для grep
      grep_pattern=$(tr '\n' '|' < "$BREAST_CANCER_GENES" | sed 's/|$//')
      
      tail -n +2 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" | \
        grep -iE "$grep_pattern" >> \
        "$PATIENT_DIR/reports/${PATIENT_ID}_breast_cancer.tsv" 2>/dev/null || true
      
      BREAST_COUNT=$(( $(wc -l < "$PATIENT_DIR/reports/${PATIENT_ID}_breast_cancer.tsv") - 1 ))
      echo "  ✓ Мутации в генах рака груди: $BREAST_COUNT"
    fi
  fi
  
  # 22. Создание сводки по качеству вариантов
  echo "Шаг 21: Создание сводки качества..."
  
  # Извлечение статистики из VCF
  TOTAL_VARIANTS=$(bcftools view "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz" 2>/dev/null | grep -v '^#' | wc -l)
  PASS_VARIANTS=$(bcftools view -i 'FILTER="PASS"' "$PATIENT_DIR/${PATIENT_ID}.annotated.vcf.gz" 2>/dev/null | grep -v '^#' | wc -l)
  
  # Анализ типов мутаций
  cat > "$PATIENT_DIR/reports/${PATIENT_ID}_variant_summary.txt" << EOF
Сводка по вариантам для пациента: $PATIENT_ID
Дата анализа: $(date)

Общая статистика:
Всего вариантов: $TOTAL_VARIANTS
Прошедших фильтры (PASS): $PASS_VARIANTS
Доля прошедших фильтры: $(if [ $TOTAL_VARIANTS -gt 0 ]; then echo "scale=2; $PASS_VARIANTS * 100 / $TOTAL_VARIANTS" | bc; else echo "0"; fi)%

Расширенные аннотации:
Всего аннотированных вариантов: $(if [ -s "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" ]; then tail -n +2 "$PATIENT_DIR/reports/${PATIENT_ID}_extended_annotations.tsv" | wc -l; else echo "0"; fi)
Значимые мутации (HIGH/MODERATE): $SIGNIFICANT_COUNT
HIGH impact мутации: $HIGH_COUNT
Мутации в генах рака груди: ${BREAST_COUNT:-0}

Инструменты аннотации:
1. SnpEff: $SNPEFF_DB
   - Предоставляет: Ген, тип мутации, impact, HGVS, позиции, биотип
   - Плагины: cancer, canonical

2. VEP: с максимальными плагинами без внешних данных
   - Частотные данные: 1KG, ESP, gnomAD (из cache)
   - Плагины: Blosum62, CSN, Downstream, NearestGene, SpliceRegion, 
              TSSDistance, UTRAnnotator, MaxEntScan
   - Дополнительно: регуляторные регионы, miRNA, проверка существующих вариантов

Файлы результатов:
1. Аннотированный VCF: ${PATIENT_ID}.annotated.vcf.gz
2. Расширенный отчет: reports/${PATIENT_ID}_extended_annotations.tsv
3. Значимые мутации: reports/${PATIENT_ID}_significant_mutations.tsv
4. HIGH impact мутации: reports/${PATIENT_ID}_high_impact.tsv
5. Мутации в генах рака груди: reports/${PATIENT_ID}_breast_cancer.tsv
6. Контроль качества: fastqc_reports/
7. Отчеты обработки: reports/

Ключевые колонки расширенного отчета:
1. Хромосома - Номер хромосомы
2. Позиция - Позиция на хромосоме
3. REF - Референсный аллель
4. ALT - Альтернативный аллель
5. Ген - Символ гена (из VEP/SnpEff)
6. Тип_мутации - Конкретный эффект (missense_variant, stop_gained и т.д.)
7. IMPACT - Уровень воздействия (HIGH, MODERATE, LOW, MODIFIER)
8. Изменение_белка - HGVSp запись (например, p.Arg123Gly)
9. Транскрипт - ID транскрипта
10. Биотип - Тип транскрипта (protein_coding, nonsense_mediated_decay и т.д.)
11. Экзон/Интрон - Номер экзона или интрона
12. Позиция_кДНК - Позиция в кДНК
13. Позиция_CDS - Позиция в кодирующей последовательности
14. Позиция_белка - Позиция в белке
15. Аминокислоты - Заменяемые аминокислоты
16. Кодоны - Заменяемые кодоны
17. Существующий_вариант - ID в базах (rsID)
18. Расстояние - DISTANCE до гена
19. Странд - STRAND (+/-)
20. Канонический - CANONICAL транскрипт (YES/NO)
21. Дополнительно_SnpEff - Доп. информация от SnpEff
22. Дополнительно_VEP - Доп. информация от VEP

Примечания:
- IMPACT HIGH: стоп-кодоны, фреймшифты, сплайсинг
- IMPACT MODERATE: миссенс, инфрейм инделы
- Канонический транскрипт обычно является основным
- HGVSp запись показывает изменение на уровне белка

Рекомендации для интерпретации:
1. В первую очередь рассмотреть HIGH impact мутации
2. Обратить внимание на мутации в генах рака груди
3. Проверить канонические транскрипты
4. Учесть популяционные частоты (если доступны)

EOF
  
  echo "ФАЙЛЫ СОЗДАНЫ:"
  echo "1. Расширенный отчет: reports/${PATIENT_ID}_extended_annotations.tsv"
  echo "2. Значимые мутации: reports/${PATIENT_ID}_significant_mutations.tsv"
  echo "3. HIGH impact мутации: reports/${PATIENT_ID}_high_impact.tsv"
  if [ -f "$BREAST_CANCER_GENES" ]; then
    echo "4. Мутации в генах рака груди: reports/${PATIENT_ID}_breast_cancer.tsv"
  fi
  echo "5. Сводка: reports/${PATIENT_ID}_variant_summary.txt"
  echo ""
  
  echo "Обработка пациента $PATIENT_ID завершена: $(date)"
done

echo "Пайплайн завершен: $(date)"