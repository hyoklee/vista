Create a new slurm job that runs MiV simulation case 6.
Save slurm job scripts and other shell scripts into `bin/` directory.
All necessary repos such as clio-core, neuroh5, NeuroFAIR, MiV-Simulator, and MiV-Simulator-Cases for simulation are available under `/work/11623/hyoklee/`
Always use the latest `dev` branch for `clio-core`.
If things don't work, make patches on new branches.
Place all build directories under `/work/11623/hyoklee/vista/`.
Test actual simulation case 6 in MiV-Simulator-Cases
using MiV-Simulator, neuroh5, and clio-core by submitting a slurm job.
Place large simulation input & output HDF5 files under `/scratch/11623/hyoklee`.
Summarize simulation performance results in an .md file.
Update `NeuroFAIR/wiki` based on the test results.
If Python is necessary, use miniconda3 under $HOME/miniconda3.
Use envs under dependency download and linking.
