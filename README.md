# Project: Wes tumor pipeline docker

## Language Selection / Выбор языка

[English](#readme-english) | [Русский](#readme-русский)

---

## **README (English)**

### Project Overview
A container for analyzing whole-exome sequencing (WES) data from tumor samples. The pipeline includes FASTQ preprocessing, alignment, variant calling (Mutect2), annotation (SnpEff, VEP), and report generation.

Requirements

- Docker (version 20.10+)
- 50–100 GB of free space (reference data + results)
- Internet access for downloading reference data and caches

Quick Start

1. Cloning the Repository

>git clone https://github.com/KypAnastasy/Wes_Tumor_Only_Pipeline_Docker.git
>cd wes-tumor-pipeline

2. Building a Docker image

>docker build -t wes-tumor-pipeline .

3.Configuration settings

Copy the configuration template and edit it if necessary:

>cp pipeline.config.example pipeline.config
>nano pipeline.config

The default settings are already suitable for working with mounted folders.

4. Loading reference data

>mkdir -p reference_ngs
>docker run -it --rm -v $(pwd)/reference_ngs:/data/reference_ngs wes-tumor-pipeline /usr/local/bin/download_references.sh

5.Preparing patient data

Patients folder structure:

>patients/
  >patient_001/
    >patient_001.fastq.gz
    >patient_001.fastq.gz

Supported files are .fastq, .fastq.gz, and .sra (will be converted to FASTQ).

6. Launching the analysis

>mkdir -p vep_cache   
>docker run --rm \
>  -v $(pwd)/reference_ngs:/data/reference_ngs \
>  -v $(pwd)/patients:/data/patients \
>  -v $(pwd)/vep_cache:/opt/vep/cache \
>  -v $(pwd)/pipeline.config:/data/pipeline.config \
>  wes-tumor-pipeline /usr/local/bin/main_analis2.sh

For convenience, you can use the run.sh script (make it executable: chmod +x run.sh).

7. Results
For each patient, the following will appear in the patients/patient_ID/ folder:

reports/ – QC reports, summaries, variant tables

*.bam, *.vcf.gz – intermediate and final files

Key reports:

reports/patient_ID_extended_annotations.tsv – all variants with annotations

reports/patient_ID_significant_mutations.tsv – mutations with IMPACT HIGH/MODERATE

reports/patient_ID_high_impact.tsv – only HIGH

reports/patient_ID_variant_summary.txt – general statistics

---

## **README (Русский)**

### Обзор проекта
Контейнер для анализа данных полногеномного секвенирования (WES) образцов опухолей. Конвейер обработки включает предварительную обработку FASTQ, выравнивание, выявление вариантов (Mutect2), аннотирование (SnpEff, VEP) и генерацию отчета.

Требования

- Docker (версия 20.10+)
- 50–100 ГБ свободного места (эталонные данные + результаты)
- Доступ к интернету для загрузки референсных данных и кэшей

Быстрый старт

1. Клонирование репозитория

>git clone https://github.com/KypAnastasy/Wes_Tumor_Only_Pipeline_Docker.git
>cd wes-tumor-pipeline

2. Создание образа Docker

>docker build -t wes-tumor-pipeline .

3. Настройки конфигурации

Скопируйте шаблон конфигурации и отредактируйте его при необходимости:

>cp pipeline.config.example pipeline.config
>nano pipeline.config

Настройки по умолчанию уже подходят для работы с смонтированными папками.

4. Загрузка референсных данных

>mkdir -p reference_ngs
>docker run -it --rm -v $(pwd)/reference_ngs:/data/reference_ngs wes-tumor-pipeline /usr/local/bin/download_references.sh

5. Подготовка данных пациентов

Структура папок с данными пациентов:

>patients/

>patient_001/

>patient_001.fastq.gz

>patient_001.fastq.gz

Поддерживаются файлы .fastq, .fastq.gz и .sra (будут преобразованы в FASTQ).

6. Запуск анализа

>mkdir -p vep_cache
>docker run --rm \
> -v $(pwd)/reference_ngs:/data/reference_ngs \
> -v $(pwd)/patients:/data/patients \
> -v $(pwd)/vep_cache:/opt/vep/cache \
> -v $(pwd)/pipeline.config:/data/pipeline.config \
> wes-tumor-pipeline /usr/local/bin/main_analis2.sh

Для удобства можно использовать скрипт run.sh (сделайте его исполняемым: chmod +x run.sh).

7. Результаты
Для каждого пациента в папке patients/patient_ID/ будут отображаться следующие файлы:

reports/ – отчеты о контроле качества, сводки, таблицы вариантов

*.bam, *.vcf.gz – промежуточные и итоговые файлы

Ключевые отчеты:

reports/patient_ID_extended_annotations.tsv – все варианты с аннотациями

reports/patient_ID_significant_mutations.tsv – мутации с ВЫСОКИМ/УМЕРЕННЫМ ВЛИЯНИЕМ

reports/patient_ID_high_impact.tsv – только ВЫСОКОЕ влияние

reports/patient_ID_variant_summary.txt – общая статистика

---
