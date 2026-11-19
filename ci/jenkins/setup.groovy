// Local Jenkins for the proof-sheet pipeline: this Mac is the 'macos' agent, one pipeline job from GitHub.
import jenkins.model.Jenkins
import org.jenkinsci.plugins.workflow.job.WorkflowJob
import org.jenkinsci.plugins.workflow.cps.CpsScmFlowDefinition
import hudson.plugins.git.GitSCM
import hudson.plugins.git.BranchSpec
import hudson.plugins.git.UserRemoteConfig

def j = Jenkins.get()
j.setLabelString("macos")
j.setNumExecutors(2)
def name = "proof-sheet"
if (j.getItem(name) == null) {
  def scm = new GitSCM([new UserRemoteConfig("https://github.com/su0xpj-bastion/proof-sheet.git", null, null, null)],
                       [new BranchSpec("*/main")], null, null, [])
  def job = j.createProject(WorkflowJob, name)
  job.setDefinition(new CpsScmFlowDefinition(scm, "Jenkinsfile"))
  job.setDescription("proof-sheet: build, workflow checks, cloud + Selenium, XCUITest (with Xcode), fault matrix, package")
  job.save()
}
j.save()
