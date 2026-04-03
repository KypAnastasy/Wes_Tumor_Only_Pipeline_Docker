# Версия Ubuntu
FROM ubuntu:22.04

# Устанавка переменного окружения для избежания интерактивных диалогов
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Moscow

# Устанавка утилит и зависимостей
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    git \
    python3 \
    python3-pip \
    python3-venv \
    openjdk-17-jre-headless \
    openjdk-17-jdk-headless \
    samtools \
    tabix \
    bcftools \
    bwa \
    fastqc \
    unzip \
    procps \
    make \
    g++ \
    zlib1g-dev \
    libbz2-dev \
    liblzma-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    libncurses5-dev \
    libncursesw5-dev \
    bc \
    libperl-dev \
    libgsl-dev \
    libsqlite3-dev \
    libmysqlclient-dev \
    postgresql-client \
    libpq-dev \
    libxml2-dev \
    libexpat1-dev \
    libgd-dev \
    libpng-dev \
    libjpeg-dev \
    libfreetype6-dev \
    libdbd-mysql-perl \
    libdbi-perl \
    libarchive-zip-perl \
    libjson-perl \
    libjson-xs-perl \
    cpanminus \
    autoconf \
    automake \
    build-essential \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Установка инструментов

# 1. SRA Toolkit 
RUN wget -q -O /tmp/sratoolkit.tar.gz "https://ftp-trace.ncbi.nlm.nih.gov/sra/sdk/current/sratoolkit.current-ubuntu64.tar.gz" \
    && tar -xzf /tmp/sratoolkit.tar.gz -C /opt/ \
    && ln -s /opt/sratoolkit.*/bin/fastq-dump /usr/local/bin/fastq-dump \
    && ln -s /opt/sratoolkit.*/bin/fasterq-dump /usr/local/bin/fasterq-dump \
    && ln -s /opt/sratoolkit.*/bin/prefetch /usr/local/bin/prefetch \
    && rm /tmp/sratoolkit.tar.gz

# 2. Fastp 
RUN apt-get update && apt-get install -y fastp

# 3. GATK 
RUN wget -q -O /tmp/gatk.zip "https://github.com/broadinstitute/gatk/releases/download/4.6.2.0/gatk-4.6.2.0.zip" \
    && unzip /tmp/gatk.zip -d /opt/ \
    && ln -s /opt/gatk-4.6.2.0/gatk /usr/local/bin/gatk \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && rm /tmp/gatk.zip

# 4. BWA-MEM2
RUN wget -q -O /tmp/bwa-mem2.tar.bz2 "https://github.com/bwa-mem2/bwa-mem2/releases/download/v2.3/bwa-mem2-2.3_x64-linux.tar.bz2" \
    && tar -xjf /tmp/bwa-mem2.tar.bz2 -C /opt/ \
    && cp /opt/bwa-mem2-2.3_x64-linux/bwa-mem2* /usr/local/bin/ \
    && rm /tmp/bwa-mem2.tar.bz2

# 5. SnpEff 
RUN apt-get update && apt-get install -y snpeff

# Создание путей
RUN find /usr -name "snpEff.jar" 2>/dev/null | head -1 | xargs -I {} sh -c ' \
    echo "#!/bin/bash" > /usr/local/bin/snpEff && \
    echo "java -Xmx4g -jar {} \$@" >> /usr/local/bin/snpEff && \
    chmod +x /usr/local/bin/snpEff'

RUN find /usr -name "SnpSift.jar" 2>/dev/null | head -1 | xargs -I {} sh -c ' \
    echo "#!/bin/bash" > /usr/local/bin/SnpSift && \
    echo "java -Xmx4g -jar {} \$@" >> /usr/local/bin/SnpSift && \
    chmod +x /usr/local/bin/SnpSift'

# 6. Устанавка htslib 
RUN cd /tmp && \
    wget -q https://github.com/samtools/htslib/releases/download/1.21/htslib-1.21.tar.bz2 && \
    tar -xjf htslib-1.21.tar.bz2 && \
    cd htslib-1.21 && \
    ./configure --prefix=/usr/local --enable-libcurl && \
    make && \
    make install && \
    ldconfig && \
    rm -rf /tmp/htslib*

# 7. Установка Perl-модулей для VEP
RUN cpanm --notest --force \
    DBI \
    Archive::Zip \
    JSON \
    LWP::Simple \
    LWP::Protocol::https \
    HTTP::Tiny \
    Crypt::SSLeay \
    Net::SSLeay \
    Mozilla::CA \
    && rm -rf /root/.cpanm

# 8. Установка Bio::DB::HTS 
RUN cpanm --force --notest Bio::DB::HTS

# 9. VEP
RUN git clone https://github.com/Ensembl/ensembl-vep.git /opt/vep \
    && cd /opt/vep \
    && git checkout release/115 \
    && perl INSTALL.pl --AUTO a --NO_HTSLIB --NO_TEST --NO_UPDATE \
    && ln -sf /opt/vep/vep /usr/local/bin/vep

# 10. Дополнительные Python пакеты
RUN pip3 install pandas numpy

# Настройка переменных окружения для Java
ENV JAVA_TOOL_OPTIONS="-Xmx4g"
ENV _JAVA_OPTIONS="-Xmx4g"

# Устанавка локали
RUN apt-get update && apt-get install -y locales \
    && locale-gen en_US.UTF-8 \
    && update-locale LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Копирование файлов внутрь образа
# Копирование основного скрипта
COPY main_analis2.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/main_analis2.sh

# Копирование вспомогательных скриптов и конфигурации
COPY download_references.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/download_references.sh
COPY pipeline.config /usr/local/bin/pipeline.config.example

# Создание точки монтирования для данных
WORKDIR /data

# Указание на то, чтобы попасть в оболочку контейнера
CMD ["/bin/bash"]