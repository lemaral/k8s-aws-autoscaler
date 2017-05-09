#!/bin/bash

minRRA=""
maxRRA=""
asgName=""
nodesDesc=""

arePodsPending() {
  # Gets pending pods older than 2min
  pendingPods=$(kubectl get pods --all-namespaces | \
    grep -E '([a-zA-Z0-9-]+\s+){2}[0-9/]+\s+Pending+(\s+[0-9]+){2}m' | \
    sed 's/m$//g' | awk '$6 >= 2 {print $1 "|" $2}')

  checkedSelectors=()

  for pod in $pendingPods; do
    IFS='|' read namespace podName <<< "$pod"

    # Gets pending pod node selector
    nodeSelector=$(kubectl describe pod -n $namespace $podName | \
      sed -n '/Node-Selectors:/{:a;p;n;/^Tolerations:/!ba}' | \
      sed 's/\t//g;s/Node-Selectors://' | sed -n ':a;N;$!ba;s/\n/,/p')

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
  results=$(echo "$nodesDesc" | grep -A3 "Total limits may be over 100 percent" | \
    grep -E '^\s+[0-9]+' | awk '{print $2, " ", $6}' | grep -oE '[0-9]{1,3}')

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

  curl -s -X POST --data-urlencode 'payload={"text": "'"$1"'"}' $SLACK_HOOK > /dev/null
}

scaleUp() {
  currentDesired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name $asgName | \
    jq '.AutoScalingGroups[].DesiredCapacity')

  aws autoscaling set-desired-capacity --auto-scaling-group-name $asgName --desired-capacity $(expr $currentDesired + 1)

  if [[ ! $? -eq 0 ]]; then
    notifySlack "Failed to scale up $asgName, hit maximum."
    return 0
  fi

  notifySlack "Scaling up $asgName."
}

scaleDown() {
  nodeName=$(echo "$nodesDesc" | grep "Name:" | awk '{print $2}' | head -n1)
  nodeId=$(echo "$nodesDesc" | grep "ExternalID:" | awk '{print $2}' | head -n1)

  aws autoscaling detach-instances --instance-ids $nodeId --auto-scaling-group-name $asgName \
    --should-decrement-desired-capacity

  if [[ ! $? -eq 0 ]]; then
    notifySlack "Failed to scale down $asgName, hit minimum."
    return 0
  fi

  kubectl drain $nodeName --ignore-daemonsets --grace-period=90 --delete-local-data --force

  sleep 30

  aws ec2 terminate-instances --instance-ids $nodeId

  notifySlack "Scaling down $asgName."
}


autoscalingNoWS=$(echo "$AUTOSCALING" | tr -d "[:space:]")
IFS=';' read -ra autoscalingArr <<< "$autoscalingNoWS"

while true; do
  for autoscaler in "${autoscalingArr[@]}"; do
    IFS='|' read minRRA maxRRA asgName <<< "$autoscaler"

    if arePodsPending; then
      echo "Pending pods..."
      echo "Scaling up $asgName."
      scaleUp
    else
      nodesDesc=$(kubectl describe nodes -l aws.autoscaling.groupName=$asgName)
      currentRRA=$(getNodesRRA)

      if [[ ${#currentRRA} -gt 0 && ${#currentRRA} -lt 4 ]]; then
        echo "$currentRRA% RRA for $asgName."

        if [[ $currentRRA > $maxRRA ]]; then
          echo "$currentRRA% > $maxRRA%. Scaling up $asgName."
          scaleUp
        elif [[ $currentRRA < $minRRA ]]; then
          echo "$currentRRA% < $minRRA%. Scaling down $asgName."
          scaleDown
        fi
      else
        notifySlack "Failed to calculate nodes RRA for $asgName."
      fi
    fi

    sleep 3
  done

  sleep $INTERVAL
done