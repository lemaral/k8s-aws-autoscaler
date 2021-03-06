#!/bin/bash

minRRA=""
maxRRA=""
asgName=""
asgRegion=""

arePodsPending() {
  # Gets pending pods older than 2min
  pendingPods=$(kubectl get pods --all-namespaces | \
    grep -E '([a-zA-Z0-9-]+\s+){2}[0-9/]+\s+Pending+(\s+[0-9]+){2}[mh]' | \
    sed 's/(m|h)$//g' | awk '$6 >= 1 { print $1 "|" $2 }')

  checkedSelectors=()

  for pod in $pendingPods; do
    IFS='|' read namespace podName <<< "$pod"

    # Gets pending pod node selector
    nodeSelector=$(kubectl describe pod -n $namespace $podName | \
      sed -n '/Node-Selectors:/{:a;p;n;/^Tolerations:/!ba}' | \
      sed 's/\t//g;s/Node-Selectors://' | tr '\n' ',' | sed 's/,$//g')

    # Checks if node selector not empty and if it hasn't already been checked against current ASG
    if [[ $nodeSelector != "" && ! "${checkedSelectors[@]}" =~ "${nodeSelector}" ]]; then
      checkedSelectors+=($nodeSelector)

      selectorMatchesASG=""
      selectorMatchesASG=$(kubectl get nodes -n $namespace -l aws.autoscaling.groupName=$asgName,$nodeSelector 2> /dev/null)

      # If node selector exists as label on the same nodes as ASG, pod is pending on that ASG
      if [[ $selectorMatchesASG != "" ]]; then
        return 0
      fi
    fi
  done

  return 1
}

getNodesRRA() {
  # Gets requested CPU and RAM resources on current ASG nodes
  results=$(kubectl describe nodes -l aws.autoscaling.groupName=$asgName | \
    grep -A3 "Total limits may be over 100 percent" | \
    grep -E '^\s+[0-9]+' | awk '{ print $2, " ", $6 }' | grep -oE '[0-9]{1,3}')

  counter=0
  sum=0
  for i in $results; do
    counter=$(expr $counter + 1)
    sum=$(expr $sum + $i)
  done

  # Returns average of requested CPU/RAM for current ASG nodes
  echo "$sum / $counter" | bc
}

notifySlack() {
  if [ -z "$SLACK_HOOK" ]; then
    return 0
  fi

  curl -s --retry 3 --retry-delay 3 -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

scaleUp() {
  currentDesired=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-name $asgName --region $asgRegion | \
    jq '.AutoScalingGroups[].DesiredCapacity')

  if [[ $currentDesired == "" ]]; then
    # If awscli request fails, retry after 3 seconds
    sleep 3

    currentDesired=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-name $asgName --region $asgRegion | \
      jq '.AutoScalingGroups[].DesiredCapacity')
  fi

  aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName \
    --desired-capacity $(expr $currentDesired + 1) --region $asgRegion

  if [[ ! $? -eq 0 ]]; then
    notifySlack "Failed to scale up $asgName, hit maximum."
    return 1
  fi

  return 0
}

scaleDown() {
  # Get the oldest node in the ASG
  nodeName=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName \
    --sort-by='{.metadata.creationTimestamp}' | awk '{ if(NR==2) print $1 }')

  nodeId=$(kubectl describe node $nodeName | grep "ExternalID:" | awk '{ print $2 }')

  if [[ $nodeName == "" || $nodeId == "" ]]; then
    # If kube api requests fail, retry after 3 seconds
    sleep 3

    nodeName=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName \
      --sort-by='{.metadata.creationTimestamp}' | awk '{ if(NR==2) print $1 }')

    nodeId=$(kubectl describe node $nodeName | grep "ExternalID:" | awk '{ print $2 }')

    if [[ $nodeName == "" || $nodeId == "" ]]; then
      notifySlack "Failed to scale down $asgName, no nodes found."
      return 1
    fi
  fi

  aws autoscaling detach-instances --instance-ids $nodeId --auto-scaling-group-name $asgName \
    --should-decrement-desired-capacity --region $asgRegion

  if [[ ! $? -eq 0 ]]; then
    notifySlack "Failed to scale down $asgName, hit minimum."
    return 1
  fi

  kubectl drain $nodeName --ignore-daemonsets --grace-period=90 --delete-local-data --force

  sleep 30

  aws ec2 terminate-instances --instance-ids $nodeId --region $asgRegion

  return 0
}

rotateNodes() {
  # Get number of nodes older than ROTATE_NODES in the current ASG
  oldNodes=$(kubectl get nodes -l aws.autoscaling.groupName=$asgName 2> /dev/null | \
    grep -E '([a-zA-Z0-9,.-]+\s+){2}[0-9]+d.*' | sed 's/d//g' | \
    awk -v days=$ROTATE_NODES '$3 > days { print }' | wc -l)

  if [[ $oldNodes != "" && $oldNodes -gt 0 ]]; then
    currentAsgNodes=$(aws autoscaling describe-auto-scaling-groups \
      --auto-scaling-group-name $asgName --region $asgRegion | \
      jq '.AutoScalingGroups[].DesiredCapacity')

    if [[ $currentAsgNodes != "" ]]; then
      desiredNodes=$(expr $currentAsgNodes + $oldNodes 2> /dev/null)

      if [[ $desiredNodes != "" && $desiredNodes -gt 0 ]]; then
        aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName \
          --desired-capacity $desiredNodes --region $asgRegion

        if [[ $? -eq 0 ]]; then
          notifySlack "Found $oldNodes nodes older than $ROTATE_NODES days in $asgName. Scaled up $oldNodes and waiting for scale down..."
        else
          notifySlack "Found $oldNodes nodes older than $ROTATE_NODES days in $asgName. Failed to scale up for nodes rotation, hit maximum."
        fi
      fi
    fi
  fi

  return 0
}


autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

RRAs=()
checkedASGsForNodesRotation=()
rotateNodesCheckTime=$(date +%s)

while true; do

  index=0
  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minRRA maxRRA asgName asgRegion <<< "$autoscaler"

    if arePodsPending; then
      echo "Pending pods. Scaling up $asgName."
      scaleUp
      if [[ $? -eq 0 ]]; then
        notifySlack "Pending pods. Scaling up $asgName."
      fi
    else
      currentRRA=$(getNodesRRA)

      # Check that currentRRA has length 1-3 (digits). If it fails, it will return "Runtime error..."
      if [[ ${#currentRRA} -gt 0 && ${#currentRRA} -lt 4 ]]; then
        # Only print currentRRA when previous reading doesn't exist or is different
        if [[ -z ${RRAs[$index]} || (! -z ${RRAs[$index]} && ${RRAs[$index]} -ne $currentRRA) ]]; then
          echo "$currentRRA% RRA for $asgName."
          RRAs[$index]=$currentRRA
        fi

        if [[ $currentRRA -gt $maxRRA ]]; then
          echo "$currentRRA% > $maxRRA%. Scaling up $asgName."
          scaleUp
          if [[ $? -eq 0 ]]; then
            notifySlack "$currentRRA% > $maxRRA%. Scaling up $asgName."
          fi
        elif [[ $currentRRA -lt $minRRA ]]; then
          echo "$currentRRA% < $minRRA%. Scaling down $asgName."
          scaleDown
          if [[ $? -eq 0 ]]; then
            notifySlack "$currentRRA% < $minRRA%. Scaling down $asgName."
          fi
        else
          # If no pending pods, no need to scale up or down: Check for old nodes rotation
          if [ ! -z "$ROTATE_NODES" ]; then
            # If current ASG hasn't been checked
            if [[ ! "${checkedASGsForNodesRotation[@]}" =~ "${asgName}" ]]; then
              # Check for nodes rotation and append current ASG to list if check interval time is good
              currentTime=$(date +%s)
              if [[ $rotateNodesCheckTime -le $currentTime ]]; then
                rotateNodes
                checkedASGsForNodesRotation+=($asgName)
              fi
            else
              # If all ASGs have been checked for nodes rotation
              if [[ ${#checkedASGsForNodesRotation[@]} -ge ${#autoscalingArr[@]} ]]; then
                # Check again for nodes rotation in ROTATE_NODES_INTERVAL seconds
                rotateNodesCheckTime=$(expr $(date +%s) + $ROTATE_NODES_INTERVAL)
                checkedASGsForNodesRotation=()
              fi
            fi
          fi
        fi
      else
        notifySlack "Failed to calculate nodes RRA for $asgName."
      fi
    fi

    (( index++ ))
    sleep 3
  done

  sleep $INTERVAL
done
