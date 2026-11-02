// Smoke test for running containers on Flow.bio with Apptainer.
//
// One task, in a small public image (python:3.12-slim, ~50 MB). It fails
// unless it is running inside an Apptainer/Singularity container, and it
// reads one uploaded file, so a pass shows that Flow pulls the image, runs
// the task inside it and stages Flow data into the container.
//
// Independent of MerXen: no nf-schema, no MerXen images, so it runs on
// Nextflow 24.10. Lives in flow/tests/, so `nextflow run` reads neither the
// root nextflow.config nor workflows/nextflow.config.

nextflow.enable.dsl = 2

params.input_file = null
params.image = "python:3.12-slim"
params.outdir = "results"

process APPTAINER_HELLO {
    container params.image
    publishDir "${params.outdir}/apptainer_hello", mode: "copy"

    input:
    path input_file

    output:
    path "apptainer_hello.txt"

    script:
    """
    image="\${APPTAINER_CONTAINER:-\${SINGULARITY_CONTAINER:-}}"
    {
        echo "nextflow_version: ${nextflow.version}"
        echo "inside_container: \$([ -n "\$image" ] && echo yes || echo no)"
        echo "container_image: \${image:-none}"
        echo "apptainer_name: \${APPTAINER_NAME:-\${SINGULARITY_NAME:-none}}"
        grep -E '^PRETTY_NAME=' /etc/os-release
        echo "python: \$(python3 --version 2>&1)"
        echo "input_file: ${input_file}"
        echo "input_bytes: \$(wc -c < '${input_file}')"
        echo "host: \$(hostname)"
    } > apptainer_hello.txt
    cat apptainer_hello.txt
    if [ -z "\$image" ]; then
        echo "FAIL: task did not run inside an Apptainer/Singularity container" >&2
        exit 1
    fi
    """
}

workflow {
    if (!params.input_file) {
        error "Missing required parameter: --input_file (any small file)"
    }
    APPTAINER_HELLO(channel.fromPath(params.input_file, checkIfExists: true))
}
