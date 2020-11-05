// Parse the manifest and sanitize the fields
process sanitize_manifest {
    container "${params.container__pandas}"
    label 'io_limited'
    errorStrategy "retry"

    input:
        path "raw.manifest.csv"
    
    output:
        path "manifest.csv", emit: manifest
    
"""
#!/usr/bin/env python3

import pandas as pd
import re

df = pd.read_csv("raw.manifest.csv")

print("Subsetting to three columns")
df = df.reindex(
    columns = [
        "GenBank FTP",
        "#Organism Name",
        "uri"
    ]
)

# Remove rows where the "GenBank FTP" doesn't start with "ftp://"
input_count = df.shape[0]
df = df.loc[
    (df["GenBank FTP"].fillna(
        ""
    ).apply(
        lambda n: str(n).startswith("ftp://")
    )) | (
        df["uri"].fillna("").apply(len) > 0
    )
]
print("%d / %d rows have valid FTP or file paths" % (input_count, df.shape[0]))

# Force organism names to be alphanumeric
df = df.apply(
    lambda c: c.apply(lambda n: re.sub('[^0-9a-zA-Z .]+', '_', n)) if c.name == "#Organism Name" else c
)

df.to_csv("manifest.csv", index=None, sep=",")
"""
}

// Parse each individual alignment file
process collectResults {
    
    container "${params.container__pandas}"
    label 'io_limited'
    errorStrategy "retry"

    input:
        file "input/*"
    
    output:
        file "*.csv.gz"
    
"""
#!/usr/bin/env python3
import gzip
import json
import os
import pandas as pd
from shutil import copyfile

# Parse the list of files to join
csv_gz_list = [
    os.path.join("input", fp)
    for fp in os.listdir("input")
]
assert len(csv_gz_list) > 0

# Make sure all inputs are .csv.gz
for fp in csv_gz_list:
    assert fp.endswith(".csv.gz"), fp

# The output table will be named for one of the inputs
output_fp = csv_gz_list[0].replace("input/", "")

# If there is only one file, just copy it to the output
if len(csv_gz_list) == 1:
    copyfile(
        csv_gz_list[0],
        output_fp
    )
else:

    print("Making a single output table")
    df = pd.concat([
        pd.read_csv(fp)
        for fp in csv_gz_list
    ], sort=True)

    print("Writing out to %s" % output_fp)
    df.reindex(
        columns = [
            "operon_context",
            "operon_size",
            "operon_ix",
            "genome_context",
            "genome_id",
            "genome_name",
            "contig_name",
            "contig_start",
            "contig_end",
            "contig_len",
            "strand",
            "alignment_length",
            "gene_name",
            "gene_start",
            "gene_end",
            "gene_len",
            "gene_cov",
            "gapopen",
            "mismatch",
            "pct_iden",
            "aligned_sequence",
            "translated_sequence",
        ]
    ).to_csv(
        output_fp, 
        index=None, 
        compression="gzip"
    )

print("Done")
"""
}


// Parse each individual alignment file and publish the final results
process collectFinalResults {
    
    container "${params.container__pandas}"
    label 'io_limited'
    publishDir "${params.output_folder}", mode: "copy", overwrite: true
    errorStrategy "retry"

    input:
        file "input/*"
    
    output:
        file "${params.output_prefix}.csv.gz"
    
"""
#!/usr/bin/env python3
import gzip
import json
import os
import pandas as pd
from shutil import copyfile

# Parse the list of files to join
csv_gz_list = [
    os.path.join("input", fp)
    for fp in os.listdir("input")
]
assert len(csv_gz_list) > 0

# Make sure all inputs are .csv.gz
for fp in csv_gz_list:
    assert fp.endswith(".csv.gz"), fp

# The output table will be named for one of the inputs
output_fp = "${params.output_prefix}.csv.gz"

# If there is only one file, just copy it to the output
if len(csv_gz_list) == 1:
    copyfile(
        csv_gz_list[0],
        output_fp
    )
else:

    print("Making a single output table")
    df = pd.concat([
        pd.read_csv(fp)
        for fp in csv_gz_list
    ], sort=True)

    print("Writing out to %s" % output_fp)
    df.to_csv(output_fp, index=None, compression="gzip")

print("Done")
"""
}

// Make a results summary PDF
process summaryPDF {
    tag "Process final results"
    container "${params.container__plotting}"
    label 'io_limited'
    errorStrategy "retry"
    publishDir "${params.output_folder}", mode: "copy", overwrite: true

    input:
        file results_csv_gz
    
    output:
        file "${params.output_prefix}.pdf"
    
"""
#!/bin/bash

set -e

make_summary_figures.py "${results_csv_gz}" "${params.output_prefix}.pdf"
"""
}

// Annotate a genome with Prokka
process prokka {
    container "staphb/prokka:latest"
    label "mem_medium"
    errorStrategy 'retry'

    input:
    tuple val(genome_id), val(genome_name), file(fasta)

    output:
    tuple val(genome_id), val(genome_name), file("OUTPUT/${genome_id}.gbk.gz")

"""#!/bin/bash

set -euxo pipefail

echo Decompressing input file
gunzip -c "${fasta}" > INPUT.fasta

echo Running Prokka

prokka \
    --outdir OUTPUT \
    --prefix "${genome_id}" \
    --cpus ${task.cpus} \
    INPUT.fasta

echo Compressing outputs

gzip OUTPUT/*

echo Done
"""

}


// Extract the regions of each GBK which contains a hit
process extractGBK {
    container "${params.container__biopython}"
    label 'io_limited'
    errorStrategy "retry"
    publishDir params.output_folder, mode: 'copy', overwrite: true

    input:
        tuple val(genome_id), val(operon_context), val(operon_ix), val(contig_name), val(genome_name), file(annotation_gbk)
        file summary_csv
    
    output:
        tuple val(operon_context), path("*/gbk/*gbk")

    script:
        template 'extractGBK.py'

}

// Make an interactive visual display for each operon context
process clinker {
    container "${params.container__clinker}"
    label 'mem_medium'
    errorStrategy "retry"
    publishDir "${params.output_folder}/html/", mode: 'copy', overwrite: true

    input:
        tuple val(operon_context), file(input_gbk_files)
    
    output:
        path "*html"

"""#!/bin/bash

OUTPUT=\$(echo "${operon_context.replaceAll(/ :: /, '_')}" | sed 's/ (\\+)/_FWD/g' | sed 's/ (-)/_REV/g')
echo \$OUTPUT

ls -lahtr

clinker *gbk --webpage \$OUTPUT.html

"""


}