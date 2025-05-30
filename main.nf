#!/usr/bin/env nextflow

nextflow.enable.dsl=2

/*
========================================================================================
        Pasteurella multocida LPS analysis pipeline
========================================================================================
 #### Documentation
 #https://github.com/vmurigneu/LPS_typing
 #### Authors
 Valentine Murigneux <v.murigneux@uq.edu.au>
========================================================================================
*/

def helpMessage() {
	log.info"""
	=========================================
	Pasteurella multocida LPS analysis pipeline v${workflow.manifest.version}
	=========================================
	Usage:
	i) Basecalling and typing workflow (soon)
	nextflow main.nf --samplesheet --samplesheet /path/to/samples.csv --pod5_dir /path/to/pod5/directory/ --outdir /path/to/outdir/ --slurm_account account
	ii) Typing workflow
	nextflow main.nf --samplesheet --samplesheet /path/to/samples.csv --fqdir /path/to/fastq/directory/ --outdir /path/to/outdir/ --slurm_account account

	Required arguments:
		--samplesheet				Path to the samplesheet file
		--fqdir					Path to the directory containing the fastq files
		--pod5_dir				Path to the directory containing the pod5 files
		--outdir				Path to the output directory to be created
		--slurm_account				Name of the Bunya account (default='a_uqds')

    """.stripIndent()
}

// Show help message
params.help = false
if (params.help){
    helpMessage()
    exit 0
}

process basecalling {
        cpus "${params.threads}"
        label "gpu"
        publishDir "$params.outdir/1_basecalling",  mode: 'copy', pattern: "*.log"
        publishDir "$params.outdir/1_basecalling",  mode: 'copy', pattern: "*.tsv"
        publishDir "$params.outdir/1_basecalling",  mode: 'copy', pattern: "*.bam"
	input:
                path(pod5_dir)
        output:
                tuple path("calls.bam"), path("summary.tsv"), emit: basecalling_results
		path("SQK-*_barcode*.bam"), emit: demultiplexed_bam
                path("summary.tsv"), emit: basecalling_summary
		path("*.bam")
		path("dorado.log")
        when:
        !params.skip_basecalling
        script:
        """
	/scratch/project_mnt/S0091/valentine/LPS/sw/dorado-0.9.0-linux-x64/bin/dorado basecaller --kit-name ${params.barcoding_kit} ${params.basecalling_model} ${pod5_dir} > calls.bam
	/scratch/project_mnt/S0091/valentine/LPS/sw/dorado-0.9.0-linux-x64/bin/dorado summary calls.bam > summary.tsv
	/scratch/project_mnt/S0091/valentine/LPS/sw/dorado-0.9.0-linux-x64/bin/dorado demux --output-dir \$PWD/demux --no-classify calls.bam
        cp .command.log dorado.log
        """
}

process nanocomp {
	cpus "${params.threads}"
	label "cpu"
	publishDir "$params.outdir/2_nanocomp",  mode: 'copy', pattern: '*log'
	publishDir "$params.outdir/2_nanocomp",  mode: 'copy', pattern: '*txt'
	publishDir "$params.outdir/2_nanocomp",  mode: 'copy', pattern: '*html'
	input:
		val(sampleID_list)
		path(fastq_files)
	output:
		tuple path("NanoStats.txt"), path("NanoComp-report.html"), emit: nanocomp_results
		path("nanocomp.log")
	when:
	!params.skip_nanocomp
	script:
	"""
	echo ${fastq_files} > fastq_files.txt
	echo ${sampleID_list} > sampleID_list.txt
	sed  "s/\\[//" sampleID_list.txt | sed "s/\\]//" | sed "s/\\,//g" > sample_list
	sampleID_list_names=\$(cat "sample_list")
	NanoComp -o \$PWD --fastq ${fastq_files} -t ${params.threads} -n \${sampleID_list_names}
	cp .command.log nanocomp.log
	"""
}

prefix="assembly"
prefix_lr="assembly_polished"
medakav="medaka"

process flye {
	cpus "${params.flye_threads}"
	tag "${sample}"
	label "high_memory" 
	label "cpu"
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: "assembly*", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: "*version.txt", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: "*info.txt"
	input:
		tuple val(sample), path(fastq)
	output:
		tuple val(sample), path(fastq), path("assembly.fasta"), emit: assembly_fasta
		tuple val(sample), path("assembly.fasta"), emit: assembly_only
		tuple val(sample), path("*assembly_info.txt"), path("assembly_graph.gfa"),path("assembly_graph.gv"), emit: assembly_graph
		path("*assembly_info.txt"), emit: assembly_info	
		path("flye.log")
		path("flye_version.txt")
	when:
	!params.skip_assembly
	shell:
	'''
	set +eu
	flye --nano-hq !{fastq} --threads !{params.flye_threads} --out-dir \$PWD !{params.flye_args} --genome-size !{params.genome_size}
	if [ -f "assembly.fasta" ]; then
		mv assembly.fasta assembly.fasta
		mv assembly_info.txt assembly_info.txt
		mv assembly_graph.gfa assembly_graph.gfa
		mv assembly_graph.gv assembly_graph.gv
	else
		touch assembly.fasta assembly_info.txt assembly_graph.gfa assembly_graph.gv
	fi
	mv assembly_info.txt !{sample}_assembly_info.txt
	flye -v 2> flye_version.txt
	cp .command.log flye.log
	'''  
}

process medaka {
	cpus "${params.medaka_threads}"
	tag "${sample}"
	label "medaka"
	label "cpu"
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: '*fasta', saveAs: { filename -> "${sample}_$filename"}
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: '*log', saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/3_assembly",  mode: 'copy', pattern: "*_version.txt" 
	input:
		tuple val(sample), path(fastq), path(draft)
	output:
		tuple val(sample), path ("flye_polished.fasta"), emit: polished_medaka
	path("medaka.log")
	path("medaka_version.txt")
	when:
	!params.skip_polishing	
	script:
	"""
	set +eu
	medaka_consensus -i ${fastq} -d ${draft} -o \$PWD -t ${params.medaka_threads} -m ${params.medaka_model}
	rm consensus_probs.hdf calls_to_draft.bam calls_to_draft.bam.bai
	if [ -f "consensus.fasta" ]; then
		mv consensus.fasta flye_polished.fasta
	else
		touch flye_polished.fasta
	fi
	cp .command.log medaka.log
	medaka --version > medaka_version.txt
 	"""
}

process quast {
        cpus "${params.threads}"
        tag "${sample}"
        label "cpu"
        publishDir "$params.outdir/$sample/4_quast",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
        publishDir "$params.outdir/$sample/4_quast",  mode: 'copy', pattern: '*tsv'
        input:
                tuple val(sample), path(assembly)
        output:
                path("*report.tsv"), emit: quast_results
                path("quast.log")
        when:
        !params.skip_quast
        script:
        """
        quast.py ${assembly} --threads ${params.threads} -o \$PWD
	sed "s/flye_polished/${sample}/" report.tsv > ${sample}_report.tsv
        rm transposed_report.tsv report.tsv
	cp .command.log quast.log
        """
}

process summary_quast {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(quast_files)
	output:
		path("4_ONT_quast_report.tsv"), emit: quast_summary
	script:
	"""
	for file in `ls *report.tsv`; do cut -f2 \$file > \$file.tmp.txt; cut -f1 \$file > rownames.txt; done
	paste rownames.txt *tmp.txt > 4_ONT_quast_report.tsv
	"""
}

process summary_flye {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(flye_info_files)
	output:
		path("3_ONT_flye_stats.tsv"), emit: flye_summary
	script:
	"""
	echo -e "sample\tasssembly_coverage\tnb_contigs\tassembly_size" > 3_ONT_flye_stats.tsv
	for file in `ls *info.txt`; do
		fileName=\$(basename \$file)
		sample=\${fileName%%_assembly_info.txt}
		grep -v length \$file > tmp
		total_length=`awk '{total_length+=\$2} END {print total_length}' tmp`
		total_cov=`awk '{total_cov+=\$2*\$3} END {print total_cov}' tmp`
		mean_cov=\$((\$total_cov/\$total_length))
		nb_contigs=`grep contig \$file | wc -l`
		echo -e \$sample\\\t\$mean_cov\\\t\$nb_contigs\\\t\$total_length  >> 3_ONT_flye_stats.tsv
	done
	"""
}

process checkm {
        cpus "${params.threads}"
        tag "${sample}"
        label "cpu"
        label "high_memory"
        publishDir "$params.outdir/$sample/5_checkm",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/5_checkm",  mode: 'copy', pattern: '*tsv'
        input:
                tuple val(sample), path(assembly)
        output:
                path("*checkm_lineage_wf_results.tsv"),  emit: checkm_results
                path("checkm.log")
        when:
        !params.skip_checkm
        script:
        """
        export CHECKM_DATA_PATH=${params.checkm_db}
        checkm data setRoot ${params.checkm_db}
        checkm lineage_wf --reduced_tree `dirname ${assembly}` \$PWD --threads ${params.threads} --pplacer_threads ${params.threads} --tab_table -f checkm_lineage_wf_results.tsv -x fasta
        mv checkm_lineage_wf_results.tsv ${sample}_checkm_lineage_wf_results.tsv
	cp .command.log checkm.log
        """
}

process summary_checkm {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(checkm_files)
	output:
		path("5_ONT_checkm_lineage_wf_results.tsv"), emit: checkm_summary
	script:
	"""
	echo -e  sampleID\\\tMarker_lineage\\\tNbGenomes\\\tNbMarkers\\\tNbMarkerSets\\\t0\\\t1\\\t2\\\t3\\\t4\\\t5+\\\tCompleteness\\\tContamination\\\tStrain_heterogeneity > header_checkm
	for file in `ls *checkm_lineage_wf_results.tsv`; do fileName=\$(basename \$file); sample=\${fileName%%_checkm_lineage_wf_results.tsv}; grep -v Bin \$file | sed s/^flye_polished/\${sample}/ >> 5_checkm_lineage_wf_results.tsv.tmp; done
	cat header_checkm 5_checkm_lineage_wf_results.tsv.tmp > 5_ONT_checkm_lineage_wf_results.tsv
	"""
}

process centrifuge_download_db {
        cpus 1
        label "high_memory"
	label "cpu"
        publishDir "$params.outdir/centrifuge_database",  mode: 'copy', pattern: "*.cf"
        input:
                val(db)
        output:
                tuple path("*.1.cf"), path("*.2.cf"), path("*.3.cf"), path("*.4.cf"), emit: centrifuge_db
        when:
        !params.skip_download_centrifuge_db
        script:
        """
        echo ${db}
        wget ${db}
        tar -xvf nt_2018_3_3.tar.gz
        """
}

process centrifuge {
        cpus "${params.centrifuge_threads}"
        tag "${sample}"
        label "cpu"
        label "very_high_memory"
        publishDir "$params.outdir/$sample/6_centrifuge",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
        publishDir "$params.outdir/$sample/6_centrifuge",  mode: 'copy', pattern: "*species_report.tsv", saveAs: { filename -> "${sample}_$filename" }
        publishDir "$params.outdir/$sample/6_centrifuge",  mode: 'copy', pattern: "*centrifuge_report.tsv"
	input:
                tuple val(sample), path(fastq), path(db1), path(db2), path(db3), path(db4)
        output:
                path("*centrifuge_report.tsv"), emit: centrifuge_report
                tuple val(sample), path("centrifuge_species_report.tsv"), emit: centrifuge_species_report
                path("centrifuge.log")
        when:
        !params.skip_centrifuge
        script:
        """
        centrifuge -x nt -U ${fastq} -S centrifuge_species_report.tsv --report-file centrifuge_report.tsv --threads ${params.centrifuge_threads}
	mv centrifuge_report.tsv ${sample}_centrifuge_report.tsv
        cp .command.log centrifuge.log
        """
}

process summary_centrifuge {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(centrifuge_files)
	output:
		tuple path("6_ONT_centrifuge_most_abundant_species.tsv"), path("6_ONT_centrifuge_pasteurella_multocida_species_abundance.tsv"), emit: centrifuge_summary
	script:
	"""
	echo -e sampleID\\\tname\\\ttaxID\\\ttaxRank\\\tgenomeSize\\\tnumReads\\\tnumUniqueReads\\\tabundance > header_centrifuge
	for file in `ls *_centrifuge_report.tsv`; do fileName=\$(basename \$file); sample=\${fileName%%_centrifuge_report.tsv}; grep -v abund \$file | sort -t\$'\t' -k7gr | head -1 | sed s/^/\${sample}\\\t/  >> 6_centrifuge_most_abundant_species.tsv.tmp; done
	cat header_centrifuge 6_centrifuge_most_abundant_species.tsv.tmp > 6_ONT_centrifuge_most_abundant_species.tsv
	for file in `ls *_centrifuge_report.tsv`; do fileName=\$(basename \$file); sample=\${fileName%%_centrifuge_report.tsv}; grep multocida \$file | grep "species"| grep -v subspecies | sed s/^/\${sample}\\\t/  >> 6_centrifuge_pasteurella_multocida_species_abundance.tsv.tmp; done
	cat header_centrifuge 6_centrifuge_pasteurella_multocida_species_abundance.tsv.tmp > 6_ONT_centrifuge_pasteurella_multocida_species_abundance.tsv
	"""
}

process kaptive3 {
        cpus "${params.threads}"
        tag "${sample}"
        label "cpu"
        publishDir "$params.outdir/$sample/7_kaptive_v3",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
        publishDir "$params.outdir/$sample/7_kaptive_v3",  mode: 'copy', pattern: '*fna'
        publishDir "$params.outdir/$sample/7_kaptive_v3",  mode: 'copy', pattern: '*tsv'
	input:
                tuple val(sample), path(assembly)
        output:
                tuple val(sample), path("*kaptive_results.tsv"), emit: kaptive_results
		path("*kaptive_results.tsv"),  emit: kaptive_tsv
                path("*fna")
                path("kaptive_v3.log")
        when:
        !params.skip_kaptive3
        script:
        """
        kaptive assembly ${params.kaptive_db_9lps} ${assembly} -f \$PWD -o kaptive_results.tsv
        mv kaptive_results.tsv ${sample}_kaptive_results.tsv
	sed s/flye_polished/${sample}/ flye_polished_kaptive_results.fna > ${sample}_flye_polished_kaptive_results.fna
	rm flye_polished_kaptive_results.fna
	cp .command.log kaptive_v3.log
        """
}

process summary_kaptive {
        publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(kaptive_files)
	output:
		path("7_ONT_kaptive_results.tsv"), emit: kaptive_summary
	script:
	"""
	echo -e sampleID\\\tBest match locus\\\tBest match type\\\tMatch confidence\\\tProblems\\\tIdentity\\\tCoverage\\\tLength discrepancy\\\tExpected genes in locus\\\tExpected genes in locus, details\\\tMissing expected genes\\\tOther genes in locus\\\tOther genes in locus, details\\\tExpected genes outside locus\\\tExpected genes outside locus, details\\\tOther genes outside locus\\\tOther genes outside locus, details\\\tTruncated genes, details\\\tExtra genes, details >  header_kaptive3
	for file in `ls *_kaptive_results.tsv`; do fileName=\$(basename \$file); sample=\${fileName%%_kaptive_results.tsv}; grep -v Assembly \$file | sed s/^flye_polished/\${sample}/  >> 7_kaptive_results.tsv.tmp; done
	cat header_kaptive3 7_kaptive_results.tsv.tmp > 7_ONT_kaptive_results.tsv
	"""
}

process minimap {
        cpus "${params.minimap_threads}"
        tag "${sample}"
        label "cpu"
	label "high_memory"
        publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*txt', saveAs: { filename -> "${sample}_$filename" }
        publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*log', saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: 'minimap2_mapped.ba*', saveAs: { filename -> "${sample}_$filename" }
	input:
                tuple val(sample), path(fastq), path(kaptive_report)
        output:
                tuple val(sample), path("minimap2_mapped.bam"), path("minimap2_mapped.bam.bai"), path(kaptive_report), emit: minimap_results
                path("minimap.log")
		path("minimap2_flagstat.txt")
        when:
        !params.skip_clair3
        shell:
        '''
	locus=`tail -1 !{kaptive_report} | cut -f3`
	ref_fasta=`grep ${locus:0:2} !{params.reference_LPS} | cut -f3`
	minimap2 -t !{params.minimap_threads} -ax map-ont -k19 -w 19 -U50,500 -g10k $ref_fasta !{fastq} > minimap2.sam
	samtools sort -o minimap2.bam -@ !{params.minimap_threads} minimap2.sam
	samtools index minimap2.bam
	samtools flagstat minimap2.bam > minimap2_flagstat.txt
	samtools view -b -F 4 minimap2.bam > minimap2_mapped.bam
	samtools index minimap2_mapped.bam
	cp .command.log minimap.log
        '''
}

process clair3 {
	cpus "${params.clair3_threads}"
        tag "${sample}"
	label "cpu"
        publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*vcf', saveAs: { filename -> "${sample}_$filename"}
        publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*log', saveAs: { filename -> "${sample}_$filename" }
        input:
                tuple val(sample), path(bam), path(bai), path(kaptive_report)
        output:
                tuple val(sample), path(bam), path(bai), path ("clair3.vcf"), path(kaptive_report), emit: clair3_results
        	path("clair3.log")
        when:
        !params.skip_clair3
        shell:
        '''
	locus=`tail -1 !{kaptive_report} | cut -f3`
	ref_gb=`grep ${locus:0:2} !{params.reference_LPS} | cut -f2`
	ref_fasta=`grep ${locus:0:2} !{params.reference_LPS} | cut -f3`
	run_clair3.sh --bam_fn=!{bam} --ref_fn=${ref_fasta} --threads=!{params.clair3_threads} --platform="ont" --model_path=!{params.clair3_model} --sample_name=!{sample} --output=\$PWD !{params.clair3_args}  --no_phasing_for_fa --include_all_ctgs --enable_long_indel
        gunzip -c merge_output.vcf.gz > merge_output.vcf
	mv merge_output.vcf clair3.vcf
	cp .command.log clair3.log
        '''
}

process snpeff {
	cpus "${params.threads}"
	tag "${sample}"
	label "cpu"
	publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*vcf'
	publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*log', saveAs: { filename -> "${sample}_$filename" }
	input:
		tuple val(sample), path(bam), path(bai), path(vcf), path(kaptive_report)
	output:
		tuple val(sample), path ("*clair3.snpeff.vcf"), emit: snpeff_results
		path("snpeff.log")
	when:
	!params.skip_snpeff
	shell:
	'''
	locus=`tail -1 !{kaptive_report} | cut -f3`
	ref_gb=`grep ${locus:0:2} !{params.reference_LPS} | cut -f2`
	mkdir -p LPS_snpeffdb
	mkdir -p snpeff_output/LPS_snpeffdb
	mkdir -p data/LPS_snpeffdb
	cp $ref_gb snpeff_output/LPS_snpeffdb/genes.gbk
	snpEff build -v -configOption 'LPS_snpeffdb'.genome='LPS_snpeffdb' -configOption 'LPS_snpeffdb'.codonTable='Bacterial_and_Plant_Plastid' -genbank -dataDir \$PWD/snpeff_output LPS_snpeffdb
	mv snpeff_output/'LPS_snpeffdb'/*.bin data/'LPS_snpeffdb'
	cp /usr/local/share/snpeff-4.3-2/snpEff.config snpEff.config
	echo 'LPS_snpeffdb.genome : LPS_snpeffdb' >> snpEff.config
	echo 'LPS_snpeffdb.codonTable : Bacterial_and_Plant_Plastid' >> snpEff.config
	snpEff eff -i vcf -o vcf -c snpEff.config -lof -nodownload -no-downstream -no-intron -no-upstream -no-utr -no-intergenic -v -configOption 'LPS_snpeffdb'.genome='LPS_snpeffdb' -configOption 'LPS_snpeffdb'.codonTable='Bacterial_and_Plant_Plastid' -stats snpeff.html LPS_snpeffdb !{vcf} > clair3.snpeff.vcf
	mv clair3.snpeff.vcf !{sample}_clair3.snpeff.vcf
	cp .command.log snpeff.log
	'''
}

process snpsift {
        cpus "${params.threads}"
        tag "${sample}"
	label "cpu"
        publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*log', saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/8_clair3",  mode: 'copy', pattern: '*vcf'
        input:
                tuple val(sample), path(vcf)
        output:
                tuple path(vcf), path ("*clair3.snpeff.high_impact.vcf"), emit: snpsift_results
                path("snpsift.log")
        when:
        !params.skip_snpeff
	shell:
	'''
	SnpSift filter "( EFF[*].IMPACT = 'HIGH' ) && (FILTER = 'PASS')" -f !{vcf} > clair3.snpeff.high_impact.vcf
	mv clair3.snpeff.high_impact.vcf !{sample}_clair3.snpeff.high_impact.vcf
	cp .command.log snpsift.log
	'''
}

process report {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*vcf'
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(clair3_files)
	output:
		tuple path("8_ONT_clair3_snpeff.vcf"), path("8_ONT_clair3_snpeff_high_impact.vcf"), path("10_ONT_genotype_report.tsv"), emit: genotype_report
	script:
	"""
	echo -e  SAMPLEID\\\tCHROM\\\tPOS\\\tID\\\tREF\\\tALT\\\tQUAL\\\tFILTER\\\tINFO\\\tFORMAT\\\tSAMPLE > header_clair3
	for file in `ls *_clair3.snpeff.high_impact.vcf`; do fileName=\$(basename \$file); sample=\${fileName%%_clair3.snpeff.high_impact.vcf}; grep -v "^#" \$file | sed s/^/\${sample}\\\t/  >> 8_clair3_snpeff_high_impact.vcf.tmp; done
	cat header_clair3 8_clair3_snpeff_high_impact.vcf.tmp > 8_ONT_clair3_snpeff_high_impact.vcf
	for file in `ls *_clair3.snpeff.vcf`; do fileName=\$(basename \$file); sample=\${fileName%%_clair3.snpeff.vcf}; grep -v "^#" \$file | sed s/^/\${sample}\\\t/  >> 8_clair3_snpeff.vcf.tmp; done
	cat header_clair3 8_clair3_snpeff.vcf.tmp > 8_ONT_clair3_snpeff.vcf
	touch 10_genotype_report.tsv
	while IFS=\$'\t' read sample chrom pos id ref alt qual filter info format formatsample; do
		while IFS=\$'\t' read db_LPStype db_genotype db_isolate db_chrom db_pos db_type db_ref db_alt db_gene; do 
			if [[ \$chrom == \$db_chrom && \$pos == \$db_pos && \$ref == \$db_ref && \$alt == \$db_alt ]]; then
				if [[ \$sample != "SAMPLEID" ]]; then
					echo "sample" \$sample": found genotype" \$db_genotype "with" \$db_type "(similar to isolate" \$db_isolate")" >> 10_ONT_genotype_report.tsv
				fi
			fi
		done < ${params.genotype_db}
	done < 8_ONT_clair3_snpeff.vcf
	"""
}

process mlst {
        cpus "${params.threads}"
        tag "${sample}"
        label "cpu"
        publishDir "$params.outdir/$sample/9_mlst",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/9_mlst",  mode: 'copy', pattern: '*csv'
        input:
                tuple val(sample), path(assembly)
        output:
                path("*mlst.csv"),  emit: mlst_results
                path("mlst.log")
        when:
        !params.skip_mlst
        script:
        """
        mlst --scheme ${params.mlst_scheme} ${assembly} --quiet --csv --threads ${params.threads} > mlst.csv
        mv mlst.csv ${sample}_mlst.csv
	cp .command.log mlst.log
        """
}

process summary_mlst {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*csv'
	input:
		path(mlst_files)
	output:
		path("9_ONT_mlst.csv"), emit: mlst_summary
	script:
	"""
	for file in `ls *_mlst.csv`; do fileName=\$(basename \$file); sample=\${fileName%%_mlst.csv};  sed s/^/\${sample}_/ \$file >> 9_ONT_mlst.csv; done
	"""
}

process bakta {
	cpus "${params.bakta_threads}"
	tag "${sample}"
	publishDir "$params.outdir/$sample/11_bakta",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/11_bakta",  mode: 'copy', pattern: '*gbff'
	publishDir "$params.outdir/$sample/11_bakta",  mode: 'copy', pattern: '*tsv'
	publishDir "$params.outdir/$sample/11_bakta",  mode: 'copy', pattern: '*tsv'
	input:
		tuple val(sample), path(assembly)
	output:
		tuple path("*.gbff"), path("*.tsv"), path("*.txt"), emit: bakta_results
		path("bakta.log")
	when:
	!params.skip_bakta
	script:
	"""
	bakta --db ${params.bakta_db} --threads ${params.bakta_threads} --prefix ${sample}_bakta --proteins ${params.bakta_protein_ref} --output \$PWD/ ${params.bakta_args} ${assembly} 
	cp .command.log bakta.log
	"""
}

process amrfinder {
	tag "${sample}"
	publishDir "$params.outdir/$sample/12_amrfinder",  mode: 'copy', pattern: "*.log", saveAs: { filename -> "${sample}_$filename" }
	publishDir "$params.outdir/$sample/12_amrfinder",  mode: 'copy', pattern: '*tsv'
	input:
		tuple val(sample), path(assembly)
	output:
		path("*.tsv"), emit: amrfinder_results
		path("amrfinder.log")
	when:
	!params.skip_amrfinder
	script:
	"""
	amrfinder -n ${assembly} -d ${params.amrfinder_db} -o \$PWD/${sample}_amrfinder.tsv --name ${sample} --threads ${params.threads} --plus ${params.amrfinder_args}
	cp .command.log amrfinder.log
	"""
} 	

process summary_amrfinder {
	publishDir "$params.outdir/10_report",  mode: 'copy', pattern: '*tsv'
	input:
		path(amrfinder_files)
	output:
		path("12_ONT_amrfinder.tsv"), emit: amrfinder_summary
	script:
	"""
	echo -e Name\\\tProtein id\\\tContig id\\\tStart\\\tStop\\\tStrand\\\tElement symbol\\\tElement name\\\tScope\\\tType\\\tSubtype\\\tClass\\\tSubclass\\\tMethod\\\tTarget length\\\tReference sequence length\\\t% Coverage of reference\\\t% Identity to reference\\\tAlignment length\\\tClosest reference accession\\\tClosest reference name\\\tHMM accession\\\tHMM description > header_amrfinder
	for file in ${amrfinder_files}; do 
		tail -n +2 "\$file" >> 12_amrfinder.tsv.tmp
	done
	cat header_amrfinder 12_amrfinder.tsv.tmp > 12_ONT_amrfinder.tsv
	"""
}

workflow {
	if (!params.skip_basecalling) {
		pod5 = Channel.fromPath("${params.pod5_dir}", checkIfExists: true )
		basecalling(pod5)
		ch_samplesheet_ONT_pod5=Channel.fromPath( "${params.samplesheet}", checkIfExists:true )
		ch_samplesheet_ONT_pod5.view()
		//rename_bam(basecalling.out.demultiplexed_bam.combine(ch_samplesheet_ONT_pod5))
	} else if (params.skip_basecalling) {
		Channel.fromPath( "${params.samplesheet}", checkIfExists:true )
        	.splitCsv(header:true, sep:',')
        	.map { row -> tuple(row.sample_id, file(row.long_fastq, checkIfExists: true)) }
        	.set { ch_samplesheet_ONT }
		ch_samplesheet_ONT.view()
		Channel.fromPath( "${params.samplesheet}", checkIfExists:true )
		.splitCsv(header:true, sep:',')
		.map { row -> file(row.long_fastq, checkIfExists: true) }
		.set { ch_samplesheet_fastq }
		if (!params.skip_nanocomp) {
			Channel.fromPath( "${params.samplesheet}", checkIfExists:true )
			.splitCsv(header:true, sep:',')
			.map { row -> row.sample_id }
			.collect()
			.set { ch_samplesheet_sampleID }
			ch_samplesheet_sampleID.toList().view()
			nanocomp(ch_samplesheet_sampleID,ch_samplesheet_fastq.collect())
		}
		if (!params.skip_assembly) {
			flye(ch_samplesheet_ONT)
			if (!params.skip_polishing) {
				medaka(flye.out.assembly_fasta)
			}
			summary_flye(flye.out.assembly_info.collect())
		}
		if (!params.skip_quast) {
			if (!params.skip_polishing) {
				quast(medaka.out.polished_medaka)
			} else if (params.skip_polishing) {
				quast(flye.out.assembly_only)
			}
			summary_quast(quast.out.quast_results.collect())
		}
		if (!params.skip_checkm) {
			if (!params.skip_polishing) {
				checkm(medaka.out.polished_medaka)
			}  else if (params.skip_polishing) {
				checkm(flye.out.assembly_only)
			}
			summary_checkm(checkm.out.checkm_results.collect())
		}
		if (!params.skip_centrifuge) {
			if (!params.skip_download_centrifuge_db) {
				ch_centrifuge_db=Channel.value( "${params.centrifuge_db_download_file}")
				centrifuge_download_db(ch_centrifuge_db)
				centrifuge(ch_samplesheet_ONT.combine(centrifuge_download_db.out.centrifuge_db))
			} else if (params.skip_download_centrifuge_db) {	
				ch_centrifuge_db=Channel.fromPath( "${params.outdir}/../databases/centrifuge/*.cf" ).collect()
				ch_centrifuge_db.view()
				centrifuge(ch_samplesheet_ONT.combine(ch_centrifuge_db))
			}
			summary_centrifuge(centrifuge.out.centrifuge_report.collect())
		}
		if (!params.skip_kaptive3) {
			if (!params.skip_polishing) {
				kaptive3(medaka.out.polished_medaka)
			} else if (params.skip_polishing) {
				kaptive3(flye.out.assembly_only)
			}
			summary_kaptive(kaptive3.out.kaptive_tsv.collect())
			if (!params.skip_clair3) {
				minimap(ch_samplesheet_ONT.join(kaptive3.out.kaptive_results))
				clair3(minimap.out.minimap_results)
				if (!params.skip_snpeff) {
					snpeff(clair3.out.clair3_results)
					snpsift(snpeff.out.snpeff_results)
					report(snpsift.out.snpsift_results.collect())
				}
			}
		}	
		if (!params.skip_mlst) {
			if (!params.skip_polishing) {
				mlst(medaka.out.polished_medaka)
			} else if (params.skip_polishing) {
				mlst(flye.out.assembly_only)
			}
			summary_mlst(mlst.out.mlst_results.collect())
		}
		if (!params.skip_bakta) {
			if (!params.skip_polishing) {
				bakta(medaka.out.polished_medaka)
			} else if (params.skip_polishing) {
				bakta(flye.out.assembly_only)
			}
		}
		if (!params.skip_amrfinder) {
			if (!params.skip_polishing) {
				amrfinder(medaka.out.polished_medaka)
			} else if (params.skip_polishing) {
				amrfinder(flye.out.assembly_only)
			}
			summary_amrfinder(amrfinder.out.amrfinder_results.collect())
		}
	}
}
