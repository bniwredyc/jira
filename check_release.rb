require 'simple_config'
require 'json'
require 'git'
require 'sendgrid-ruby'
require_relative 'lib/check'
require_relative 'lib/repo'

EMAIL_FROM = SimpleConfig.sendgrid.from
SG_USER = SimpleConfig.sendgrid.user
SG_KEY = SimpleConfig.sendgrid.pass
SKIPPED_EMAILS = %w(services@onetwotrip.com default@default.com).freeze

if !ENV['payload'] || ENV['payload'].empty?
  print "No payload - no result\n"
  exit 2
end

payload = JSON.parse ENV['payload']

repo_name = payload['repository']['name']
print "Working with #{repo_name}\n"

WORKDIR = SimpleConfig.git.workdir
Dir.mkdir WORKDIR unless Dir.exist? WORKDIR
Dir.chdir WORKDIR || './'

unless payload['push']['changes'][0]['new']
  puts 'Branch was deleted, nothing to do'
  exit 0
end

changes = payload['push']['changes'][0]
repo_url = hanges['new']['links']['html']['href']
new_commit = changes['new']['target']['hash']
old_commit = changes.dig('old', 'target', 'hash') || 'master'

g_rep = GitRepo.new repo_url

puts "Old: #{old_commit}; new: #{new_commit}"
author_name = g_rep.git.gcommit(new_commit).author.name
email_to = g_rep.git.gcommit(new_commit).author.email

exit 0 if SKIPPED_EMAILS.include? email_to # Bot commits skipped by Zubkov's request

res_text = ''
merge_errors = ''

g_rep.checkout new_commit
if old_commit == 'master'
  begin
    g_rep.merge! 'master'
  rescue Git::GitExecuteError => e
    merge_errors << "Failed to merge master to commit #{new_commit}.\nGit had this to say:\n#{e.message}\n\n"
    g_rep.abort_merge!
    g_rep.checkout new_commit
  end
end

res_text << g_rep.check_diff('HEAD', old_commit)

exit 0 if res_text.empty?

print res_text
print "Will be emailed to #{email_to}\n"

mail = SendGrid::Mail.new do |m|
  m.to = email_to
  m.from = EMAIL_FROM
  m.subject = "JSCS/JSHint: проблемы с комитом в #{payload['repository']['full_name']}"
  msg = ''
  msg << "Привет <a href=\"mailto:#{email_to}\">#{author_name}</a>!<br />
Ты <a href=\"https://bitbucket.org/#{payload['repository']['full_name']}/commits/#{new_commit}\">коммитнул</a>,
 молодец.<br />"
  msg << "Только вот у тебя мастер не мержится в твою ветку.<br /><pre>#{merge_errors}</pre>" unless merge_errors.empty?
  msg << "А вот что имеют тебе сказать JSCS и JSHint:<pre>#{res_text}</pre>"
  m.html = msg
end

SendGrid::Client.new(api_user: SG_USER, api_key: SG_KEY).send mail
