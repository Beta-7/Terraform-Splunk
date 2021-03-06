# Specify the provider and access details
provider "aws" {
  region = "${var.region}"
}

###################### ELB PART ######################
resource "aws_elb" "search" {
    name = "splunk-elb"
    tags {
        Name = "splunk_elb"
    }
    internal        = "${var.elb_internal}"
    subnets         = ["${split(",", var.subnets)}"]
    security_groups = ["${aws_security_group.elb.id}"]
    listener {
        instance_port     = "${var.httpport}"
        instance_protocol = "http"
        lb_port           = 80
        lb_protocol       = "http"
    }
    health_check {
        healthy_threshold    =  2
        unhealthy_threshold  =  2
        timeout              =  3
        #Health check does not like redirects so we test a "final" url
        target               =  "HTTP:${var.httpport}/en-US/account/login"
        interval             =  5
    }
    cross_zone_load_balancing    =  true
    idle_timeout                 =  400
    connection_draining          =  true
    connection_draining_timeout  =  400
}

resource "aws_lb_cookie_stickiness_policy" "search" {
    name                      =  "splunk-lb-policy"
    load_balancer             =  "${aws_elb.search.id}"
    lb_port                   =  80
    cookie_expiration_period  =  1800
}

resource "aws_app_cookie_stickiness_policy" "splunk" {
    name            = "${var.pretty_name}-stickiness-policy"
    load_balancer   = "${aws_elb.search.id}"
    lb_port         = 80
    #Cookie name is base on the web server port
    cookie_name     = "session_id_${var.httpport}"
}
###################### Security Groups Part ######################
resource "aws_security_group" "elb" {
    name        = "sg_splunk_elb"
    description = "Used in the terraform"
    vpc_id      = "${var.vpc_id}"
    # HTTP access from anywhere
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # HTTPS access from anywhere
    ingress {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
    # outbound internet access
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_security_group" "all" {
    name        = "sg_splunk_all"
    description = "Common rules for all"
    vpc_id      = "${var.vpc_id}"
    # Allow SSH admin access
    ingress {
        from_port   = "22"
        to_port     = "22"
        protocol    = "tcp"
        cidr_blocks = ["${var.admin_cidr_block}"]
    }
    # Allow Web admin access
    ingress {
        from_port   = "${var.httpport}"
        to_port     = "${var.httpport}"
        protocol    = "tcp"
        cidr_blocks = ["${var.admin_cidr_block}"]
    }
    # full outbound  access
    egress {
        from_port   = 0
        to_port     = 0
        protocol    = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }
}

resource "aws_security_group_rule" "interco" {
    # Allow all ports between splunk servers
    type                        = "ingress"
    from_port                   = "0"
    to_port                     = "0"
    protocol                    = "-1"
    security_group_id           = "${aws_security_group.all.id}"
    source_security_group_id    = "${aws_security_group.all.id}"
}

resource "aws_security_group" "searchhead" {
    name             = "sg_splunk_searchhead"
    description      = "Used in the  terraform"
    vpc_id           = "${var.vpc_id}"
    #HTTP  access  from  the  ELB
    ingress {
        from_port        = "${var.httpport}"
        to_port          = "${var.httpport}"
        protocol         = "tcp"
        security_groups  = ["${aws_security_group.elb.id}"]
    }
}

###################### Templates part ######################
resource "template_file" "serverclass_conf" {
    template    = "${file("${path.module}/serverclass_conf.tpl")}"
    vars     {
        master_ip        = "${aws_instance.master.private_ip}"
    }
}

resource "template_file" "web_conf" {
    template    = "${file("${path.module}/web_conf.tpl")}"
    vars     {
        httpport        = "${var.httpport}"
        mgmtHostPort    = "${var.mgmtHostPort}"
    }
}

resource "template_file" "deploymentclient_conf" {
    template    = "${file("${path.module}/deploymentclient_conf.tpl")}"
    vars     {
        mgmtHostPort        = "${var.mgmtHostPort}"
        deploymentserver_ip = "${var.deploymentserver_ip}"
    }
}

resource "template_file" "server_conf_master" {
    template    = "${file("${path.module}/server_conf_master.tpl")}"
    vars     {
        replication_factor  = "${var.replication_factor}"
        search_factor       = "${var.search_factor}"
        pass4SymmKey        = "${var.pass4SymmKey}"
    }
}

resource "template_file" "server_conf_indexer" {
    template    = "${file("${path.module}/server_conf_indexer.tpl")}"
    vars    {
        mgmtHostPort        = "${var.mgmtHostPort}"
        master_ip           = "${aws_instance.master.private_ip}"
        pass4SymmKey        = "${var.pass4SymmKey}"
        replication_port    = "${var.replication_port}"
    }
}

resource "template_file" "server_conf_searchhead" {
    template    = "${file("${path.module}/server_conf_searchhead.tpl")}"
    vars    {
        mgmtHostPort        = "${var.mgmtHostPort}"
        master_ip           = "${aws_instance.master.private_ip}"
        pass4SymmKey        = "${var.pass4SymmKey}"
    }
}

resource "template_file" "user_data_master" {
    template    = "${file("${path.module}/user_data.tpl")}"
    vars    {
        deploymentclient_conf_content   = <<EOF
[deployment-client]
serverRepositoryLocationPolicy = rejectAlways
repositoryLocation = \$SPLUNK_HOME/etc/master-apps
${template_file.deploymentclient_conf.rendered}
EOF
        server_conf_content             = "${template_file.server_conf_master.rendered}"
        serverclass_conf_content        = ""
        web_conf_content                = "${template_file.web_conf.rendered}"
        role                            = "master"
    }
}

resource "template_file" "user_data_deploymentserver" {
    template    = "${file("${path.module}/user_data.tpl")}"
    vars    {
        # Deployment server cannot be it's own client
        deploymentclient_conf_content   = ""
        server_conf_content             = ""
        serverclass_conf_content        = "${template_file.serverclass_conf.rendered}"
        web_conf_content                = "${template_file.web_conf.rendered}"
        role                            = "deploymentserver"
    }
}

resource "template_file" "user_data_indexer" {
    template    = "${file("${path.module}/user_data.tpl")}"
    vars    {
        # Indexers are deploy clients for the cluster master
        deploymentclient_conf_content   = ""
        server_conf_content             = "${template_file.server_conf_indexer.rendered}"
        serverclass_conf_content        = ""
        web_conf_content                = "${template_file.web_conf.rendered}"
        role                            = "indexer"
    }
}

resource "template_file" "user_data_searchhead" {
    template    = "${file("${path.module}/user_data.tpl")}"
    vars    {
        deploymentclient_conf_content   = "${template_file.deploymentclient_conf.rendered}"
        server_conf_content             = "${template_file.server_conf_searchhead.rendered}"
        serverclass_conf_content        = ""
        web_conf_content                = "${template_file.web_conf.rendered}"
        role                            = "searchhead"
    }
}

###################### Instances part ######################
resource "aws_instance" "master" {
    connection {
        user = "${var.instance_user}"
    }
    tags {
        Name = "splunk_master"
    }
    ami                         = "${var.ami}"
    instance_type               = "${var.instance_type_indexer}"
    key_name                    = "${var.key_name}"
    subnet_id                   = "${element(split(",", var.subnets), "0")}"
    user_data                   = "${template_file.user_data_master.rendered}"
    vpc_security_group_ids      = ["${aws_security_group.all.id}"]
}

resource "aws_instance" "deploymentserver" {
    connection {
        user = "${var.instance_user}"
    }
    tags {
        Name = "splunk_deploymentserver"
    }
    ami                         = "${var.ami}"
    instance_type               = "${var.instance_type_indexer}"
    key_name                    = "${var.key_name}"
    private_ip                  = "${var.deploymentserver_ip}"
    subnet_id                   = "${element(split(",", var.subnets), "0")}"
    user_data                   = "${template_file.user_data_deploymentserver.rendered}"
    vpc_security_group_ids      = ["${aws_security_group.all.id}"]
}

resource "aws_instance" "indexer" {
    count                       = "${var.count_indexer}"
    connection {
        user = "${var.instance_user}"
    }
    tags {
        Name = "splunk_indexer"
    }
    ami                         = "${var.ami}"
    instance_type               = "${var.instance_type_indexer}"
    key_name                    = "${var.key_name}"
    subnet_id                   = "${element(split(",", var.subnets), count.index)}"
    user_data                   = "${template_file.user_data_indexer.rendered}"
    vpc_security_group_ids      = ["${aws_security_group.all.id}"]
}
###################### searchhead autoscaling part ######################
resource "aws_launch_configuration" "searchhead" {
    name = "lc_splunk_searchhead"
    connection {
        user = "${var.instance_user}"
    }
    image_id                    = "${var.ami}"
    instance_type               = "${var.instance_type_searchhead}"
    key_name                    = "${var.key_name}"
    user_data                   = "${template_file.user_data_searchhead.rendered}"
    security_groups             = ["${aws_security_group.all.id}", "${aws_security_group.searchhead.id}"]
}

resource "aws_autoscaling_group" "searchhead" {
    name = "asg_splunk_searchhead"
    availability_zones         = ["${split(",", var.availability_zones)}"]
    vpc_zone_identifier        = ["${split(",", var.subnets)}"]
    min_size                   = "${var.asg_searchhead_min}"
    max_size                   = "${var.asg_searchhead_max}"
    desired_capacity           = "${var.asg_searchhead_desired}"
    health_check_grace_period  = 300
    health_check_type          = "EC2"
    launch_configuration       = "${aws_launch_configuration.searchhead.name}"
    load_balancers             = ["${aws_elb.search.name}"]
    tag {
        key                 = "Name"
        value               = "splunk_searchhead"
        propagate_at_launch = true
    }
}
