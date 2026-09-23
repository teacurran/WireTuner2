package com.villagecompute.wiretuner.api.persistence;

import java.util.UUID;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** A team's company-workspace binding: SSO connection and the sharing switches. */
@Entity
@Table(name = "workspace")
public class Workspace {

    @Id
    @Column(name = "team_id")
    public UUID teamId;

    @Column(name = "sso_idp_alias")
    public String ssoIdpAlias;

    @Column(name = "require_sso", nullable = false)
    public boolean requireSso;

    @Column(name = "auto_admit", nullable = false)
    public boolean autoAdmit;

    @Column(name = "restrict_sharing", nullable = false)
    public boolean restrictSharing;

    @Column(name = "restrict_package_export", nullable = false)
    public boolean restrictPackageExport;
}
