# rhacs_demo.automation

Ansible collection used by the `agd_v2/rhacs-demo-cnv` catalog.

`ocp4_workload_rhacs_preview` runs after RHACS and OpenShift Lightspeed. It writes the RHACS 5.0 technology-preview environment variables onto the Central custom resource, and it grants Central access to Lightspeed so risk enrichment can call the in-cluster API.

`ocp4_workload_rhacs_vm_credentials` creates namespace `rhel-webserver` and Secret `rhacs-vm-satellite`. It does not create a VirtualMachine. `basic-setup/deploy-rhel-webserver.sh` reads that secret and creates the guest on a worker.
