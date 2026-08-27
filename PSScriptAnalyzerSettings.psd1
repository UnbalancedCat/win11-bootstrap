@{
    # The bootstrapper is an interactive console application. Write-Host is
    # intentional for prompts, plans, and the final status table.
    #
    # ShouldProcess is implemented once at the public bootstrap boundary. The
    # internal state-changing helpers are not standalone cmdlets and must not
    # create independent confirmation behavior.
    #
    # Several plural helper names describe collection-returning APIs and are
    # kept stable. All other warning and error rules remain enabled.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
