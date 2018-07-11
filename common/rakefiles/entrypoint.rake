require "rake/clean"
require_relative "./vars.rb"

if @env.nil?
  puts "  ERROR: @env must be set!"
  puts "  This is a problem in rake code."
  puts "  Set @env before importing this rakefile."
  raise ArgumentError, "@env must be set"
end
if @project_type.nil?
  puts "  ERROR: @project_type must be set!"
  puts "  This is a problem in rake code."
  puts "  Set @project_type before importing this rakefile."
  raise ArgumentError, "@project_type must be set"
end

@exekube_cmd = "docker-compose run --rm --service-ports xk"

desc "Create cluster and deploy GPII components to it"
task :default => :deploy

task :set_vars do
  Vars.set_vars(@env, @project_type)
  Vars.set_secrets()
end

@dot_config_path = "../../.config/#{@env}"
CLOBBER << @dot_config_path

@gcp_creds_file = "#{@dot_config_path}/gcloud/credentials.db"
desc "[ADVANCED] Authenticate and generate GCP credentials (gcloud auth login)"
task :auth => [:set_vars, @gcp_creds_file]
rule @gcp_creds_file do
  sh "#{@exekube_cmd} gcloud auth login"
end

@kubectl_creds_file = "#{@dot_config_path}/kube/config"
desc "[ADVANCED] Fetch kubectl credentials (gcloud auth login)"
task :configure_kubectl => [:set_vars, @gcp_creds_file, @kubectl_creds_file]
rule @kubectl_creds_file do
  # This duplicates information in terraform code, 'k8s-cluster'
  cluster_name = 'k8s-cluster'
  # This duplicates information in terraform code, 'zone'. Could be a variable
  # with some plumbing.
  zone = 'us-central1-a'
  sh "#{@exekube_cmd} gcloud container clusters get-credentials #{cluster_name} --zone #{zone} --project #{ENV["TF_VAR_project_id"]}"
end

desc "[NOT IDEMPOTENT, RUN ONCE PER ENVIRONMENT] Initialize GCP Project where this environment's resources will live"
task :project_init => [:set_vars, @gcp_creds_file] do
  # Steps to initialize GCP with a minimum set of resources to allow Terraform
  # create the rest of the infrastructure.
  # These steps are the same found in this tutorial:
  # https://cloud.google.com/community/tutorials/managing-gcp-projects-with-terraform

  require 'json'
  output = `#{@exekube_cmd} gcloud projects list --format='json' --filter='name:gpii-gcp-prd'`
  hash = JSON.parse(output)
  if hash.empty?
    puts "gpii-gcp-prd not found, I'll create a new one"
    sh "
      #{@exekube_cmd} gcloud projects create gpii-gcp-prd \
      --organization #{ENV["ORGANIZATION_ID"]} \
      --set-as-default"
  else
    sh "
      #{@exekube_cmd} gcloud config set project gpii-gcp-prd"
  end
  sh "
    #{@exekube_cmd} gcloud beta billing projects link gpii-gcp-prd \
    --billing-account #{ENV["BILLING_ID"]}"

  output = `#{@exekube_cmd} gcloud iam service-accounts list --format='json' \
            --filter='email:terraform@gpii-gcp-prd.iam.gserviceaccount.com'`
  hash = JSON.parse(output)
  if hash.empty?
    sh "#{@exekube_cmd} gcloud iam service-accounts create terraform \
        --display-name 'CI account'"
  end

  output = `#{@exekube_cmd} gcloud iam service-accounts keys list \
            --iam-account=terraform@gpii-gcp-prd.iam.gserviceaccount.com --format='json'`
  hash = JSON.parse(output)
  if hash.empty?
    sh "#{@exekube_cmd} gcloud iam service-accounts keys create #{ENV["TF_VAR_serviceaccount_key"]} \
        --iam-account terraform@gpii-gcp-prd.iam.gserviceaccount.com"
  end
  sh "#{@exekube_cmd} gcloud projects add-iam-policy-binding gpii-gcp-prd \
            --member serviceAccount:terraform@gpii-gcp-prd.iam.gserviceaccount.com \
            --role roles/viewer"

  sh "#{@exekube_cmd} gcloud projects add-iam-policy-binding gpii-gcp-prd \
            --member serviceAccount:terraform@gpii-gcp-prd.iam.gserviceaccount.com \
            --role roles/storage.admin"

  output = `#{@exekube_cmd} gcloud services list --format='json'`
  hash = JSON.parse(output)
  servicesEnabled = []
  hash.each do |service|
    servicesEnabled.push(service["serviceName"])
  end


  sh "#{@exekube_cmd} gcloud services enable cloudresourcemanager.googleapis.com" unless servicesEnabled.include?("cloudresourcemanager.googleapis.com")
  sh "#{@exekube_cmd} gcloud services enable cloudbilling.googleapis.com" unless servicesEnabled.include?("cloudbilling.googleapis.com")
  sh "#{@exekube_cmd} gcloud services enable iam.googleapis.com" unless servicesEnabled.include?("iam.googleapis.com")
  sh "#{@exekube_cmd} gcloud services enable compute.googleapis.com" unless servicesEnabled.include?("compute.googleapis.com")

  sh "#{@exekube_cmd} gcloud organizations add-iam-policy-binding #{ENV["ORGANIZATION_ID"]} \
      --member serviceAccount:terraform@gpii-gcp-prd.iam.gserviceaccount.com \
      --role roles/resourcemanager.projectCreator"

  sh "#{@exekube_cmd} gcloud organizations add-iam-policy-binding #{ENV["ORGANIZATION_ID"]} \
      --member serviceAccount:terraform@gpii-gcp-prd.iam.gserviceaccount.com \
      --role roles/billing.user"

  `#{@exekube_cmd} gsutil ls gs://gpii-gcp-prd-tfstate`
  if $?.exitstatus != 0
    sh "#{@exekube_cmd} gsutil mb gs://gpii-gcp-prd-tfstate"
  end

  sh "#{@exekube_cmd} gsutil versioning set on gs://gpii-gcp-prd-tfstate"

end

# This duplicates information in docker-compose.yaml,
# TF_VAR_serviceaccount_key.
@serviceaccount_key_file = "secrets/kube-system/owner.json"
desc "[ADVANCED] Create credentials for projectowner service account"
task :creds => [:set_vars, @gcp_creds_file, @serviceaccount_key_file]
rule @serviceaccount_key_file do
  # TODO: This command is duplicated from exekube's gcp-project-init (and
  # hardcodes 'projectowner' instead of $SA_NAME which is only defined in
  # gcp-project-init). If gcp-project-init becomes idempotent (GPII-2989,
  # https://github.com/exekube/exekube/issues/92), or if this 'keys create'
  # step moves somewhere else in exekube, call this command from that place
  # instead.
  sh "
    #{@exekube_cmd} sh -c 'gcloud iam service-accounts keys create $TF_VAR_serviceaccount_key \
      --iam-account projectowner@$TF_VAR_project_id.iam.gserviceaccount.com'"
end
CLOBBER << @serviceaccount_key_file

desc "[ADVANCED] Tell gcloud to use TF_VAR_project_id as the default Project; can be useful after 'rake clobber'"
task :set_current_project => [:set_vars, @gcp_creds_file, @serviceaccount_key_file] do
  sh "#{@exekube_cmd} gcloud config set project #{ENV["TF_VAR_project_id"]}"
end

desc "[ADVANCED] Create or update low-level infrastructure"
task :apply_infra => [:set_vars, @gcp_creds_file, @serviceaccount_key_file] do
  sh "#{@exekube_cmd} up live/#{@env}/infra"
end

desc "[ADVANCED] Plan low-level infrastructure"
task :plan_infra => [:set_vars, @gcp_creds_file, @serviceaccount_key_file] do
  sh "#{@exekube_cmd} plan live/#{@env}/infra"
end

desc "Plan cluster and deploy GPII components to it"
task :plan => [:set_vars, @gcp_creds_file, @serviceaccount_key_file, :plan_infra] do
  sh "#{@exekube_cmd} plan"
end

desc "Create cluster and deploy GPII components to it"
task :deploy => [:set_vars, @gcp_creds_file, @serviceaccount_key_file, @kubectl_creds_file, :apply_infra] do
  sh "#{@exekube_cmd} up"
end

desc "Destroy cluster and low-level infrastructure"
task :destroy_infra => [:set_vars, @gcp_creds_file, @serviceaccount_key_file, :destroy] do
  sh "#{@exekube_cmd} down live/#{@env}/infra"
end

desc "Undeploy GPII compoments and destroy cluster"
task :destroy => [:set_vars, @gcp_creds_file, @serviceaccount_key_file, @kubectl_creds_file] do
  sh "#{@exekube_cmd} down"
end

desc '[ADVANCED] Run arbitrary exekube command -- rake xk"[kubectl get pods]"'
task :xk, [:cmd] => :set_vars do |taskname, args|
  if args[:cmd]
     sh "#{@exekube_cmd} #{args[:cmd]}"
  else
     sh "#{@exekube_cmd} sh"
  end
end

desc '[ADVANCED] Deploy provided module into the cluster -- rake deploy_module"[k8s/kube-system/cert-manager]"'
task :deploy_module, [:module] => [:set_vars, @gcp_creds_file] do |taskname, args|
  if args[:module].nil?
    puts "  ERROR: args[:module] must be set and point to Terragrunt directory!"
    raise ArgumentError, "args[:module] must be set"
  elsif !File.directory?(args[:module])
    puts "  ERROR: args[:module] must point to Terragrunt directory!"
    raise IOError, "args[:module] must point to existing Terragrunt directory"
  end
  sh "#{@exekube_cmd} up live/#{@env}/#{args[:module]}"
end

desc '[ADVANCED] Destroy provided module in the cluster -- rake destroy_module"[k8s/kube-system/cert-manager]"'
task :destroy_module, [:module] => [:set_vars, @gcp_creds_file] do |taskname, args|
  if args[:module].nil?
    puts "  ERROR: args[:module] must be set and point to Terragrunt directory!"
    raise ArgumentError, "args[:module] must be set"
  elsif !File.directory?(args[:module])
    puts "  ERROR: args[:module] must point to Terragrunt directory!"
    raise IOError, "args[:module] must point to existing Terragrunt directory"
  end
  sh "#{@exekube_cmd} down live/#{@env}/#{args[:module]}"
end

# vim: et ts=2 sw=2:
