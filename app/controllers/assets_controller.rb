class AssetsController < ApplicationController  
  before_filter :find_user, :except => [:radio]
  before_filter :find_asset, :only => [:show, :edit, :update, :destroy, :stats]
  
  # we check to see if the current_user is authorized based on the asset.user
  before_filter :require_login, :except => [:index, :show, :latest, :radio, :listen_feed]
  before_filter :set_user_agent, :find_referrer, :prevent_abuse, :only => :show
  
  # user agent whitelist
  # cfnetwork = Safari on osx 10.4 *only* when it tries to download
  @@valid_listeners = ['msie','webkit','quicktime','gecko','mozilla','netscape','itunes','chrome','opera', 'safari','cfnetwork','facebookexternalhit','ipad','iphone','apple','facebook']
 
  # user agent black list
  @@bots = ['bot','spider','baidu','mp3bot'] 
  
  # home page
  def latest
    respond_to do |wants|
      wants.html do
        @page_title = @description = "Latest #{@limit} uploaded mp3s" if params[:latest]
        @tab = 'home'
        @assets = Asset.latest.includes(:user => :pic).limit(5)
        set_related_lastest_variables
      end
      wants.rss do 
        @assets = Asset.latest(50)
      end
      wants.json do
        @assets = Asset.limit(500).includes(:user)
        render :json => @assets.to_json(:only => [:name, :title, :id], :methods => [:name], :include =>{:user => {:only => :name, :method => :name}})
      end
    end
  end
  
  # index serves assets for a specific user
  def index
    @page_title = "All music by " + @user.name 
    @assets = @user.assets.recent.paginate(:per_page => 200, :page => params[:page])

    respond_to do |format|
      format.html # index.rhtml
      format.xml  { render :xml => @assets.to_xml }
      format.rss  { render :xml => @assets.to_xml }
      format.js do  render :update do |page| 
          page.replace 'stash', :partial => "assets"
        end
      end
      format.json do
        cached_json = cache("tracksby"+@user.login) do
          '{ "records" : ' + @assets.to_json(:methods => [:name, :type, :length, :seconds], :only => [:id,:name,:listens_count, :description,:permalink,:hotness, :user_id, :created_at]) + '}'
        end
        render :json => cached_json
      end
    end
  end

  def show
    respond_to do |format|
      format.html do
        @assets = [@asset]
        set_related_show_variables
      end
      format.mp3 do
        register_listen
        redirect_to @asset.mp3.url
      end
    end
  end

  def hot_track
    respond_to do |format|
      format.mp3 do
        pos = params[:position]
        pos = 1 unless pos && pos.to_i < 25
        @asset = Asset.limit(pos).order('hotness DESC').last
        register_listen
        redirect_to @asset.mp3.url
      end
    end
  end

  def radio
    params[:source] = (params[:source] || cookies[:radio] || 'latest')
    @channel = params[:source].humanize
    @page_title = "alonetone Radio: #{@channel}" 
    @assets = Asset.radio(params[:source], params, current_user)
  end
  
  def top
    top = (params[:top] && params[:top].to_i < 50) ? params[:top] : 40
    @page_title = "Top #{top} tracks"
    @assets = Asset.limit(top).order('hotness DESC')
    respond_to do |wants|
      wants.html 
      wants.rss
    end
  end
  
  def search
    @assets = Asset.where(["assets.filename LIKE ? OR assets.title LIKE ?", "%#{params[:search]}%","%#{params[:search]}%"]).limit(10)
    render :partial => 'results', :layout => false
  end

  def new
    redirect_to signup_path unless logged_in?
    @tab = 'upload' if current_user == @user
    @asset = Asset.new
  end

  def edit
    @descriptionless = @user.assets.descriptionless
    @allow_reupload = true
  end

  def mass_edit
    redirect_to_default and return false unless logged_in? and current_user.id == @user.id or admin?
    @descriptionless = @user.assets.descriptionless
    if params[:assets] # expects comma seperated list of ids
      @assets = [@user.assets.where(:id => params[:assets])].flatten
    end
    @assets = @user.assets unless @assets.present?
  end
  
  def mass_update
    
  end

  def create
    extract_assets_from_params

    flashes = ''
    good = false

    @assets.each do |asset| 
      if !asset.new_record? 
        flashes += "#{CGI.escapeHTML asset.mp3_file_name} uploaded!<br/>"
        good = true
      else
        errors = asset.errors.collect{|attr, msg| msg }
        flashes  += "'#{CGI.escapeHTML asset.mp3_file_name}' failed to upload: <br/>#{errors}<br/>"
      end
    end

    if good 
      flash[:ok] = flashes + "<br/>Now, check the title and add description for your track(s)"
      redirect_to mass_edit_user_tracks_path(current_user, :assets => (@assets.collect(&:id)))
    else
     if @assets.present?
       flash[:error] = flashes.html_safe
      else
        flashe[:error] = "Oh noes! Either that file was not an mp3 or you didn't actually pick a file to upload. Need help? Search or ask for help the forums or email support@alonetone.com" 
      end
      redirect_to new_user_track_path(current_user)
    end 
  end

  # PUT /assets/1
  # PUT /assets/1.xml
  def update
    result =  @asset.update_attributes(params[:asset])
    if request.xhr?
      result ? head(:ok) : head(:bad_request)
    else
      if result
        redirect_to user_track_url(@asset.user.login, @asset.permalink) 
      else
        flash[:error] = "There was an issue with updating that track"
        render :action => "edit" 
      end
    end
  end

  def destroy
    @asset.destroy
    flash[:ok] = "We threw the puppy away. No one can listen to it again " << 
                 "(unless you reupload it, of course ;)"
                 
    respond_to do |format|
      format.html { redirect_to user_tracks_url(current_user) }
      format.xml  { head :ok }
    end
  end
  
  def stats
    respond_to do |format|
      format.xml
    end
  end
  
  def listen_feed
    @tracks = @user.new_tracks_from_followees(15)
    respond_to do |format|
      format.rss
    end
  end
  
  protected
    
  def not_found
    flash[:error] = "We didn't find that mp3 from #{@user.name}, sorry. Maybe it is here?" 
    redirect_to user_tracks_path(@user) 
  end
  
  def user_has_tracks_from_followees?
    logged_in? and current_user.has_followees?
  end
  
  def extract_assets_from_params
    @assets = []
    params[:asset_data].each do |file|
      unless file.is_a?(String)
        @assets << current_user.assets.create(:mp3 => file)
      end
    end
  end
  
  def find_referrer
    @referrer = case params[:referrer]
      when 'itunes'   then 'itunes'
      when 'download' then 'download'
      when 'home'     then 'alonetone home'
      when 'facebook' then 'facebook'
      when 'listenapp' then 'http://ListenApp.com'
      when nil        then 'direct hit'
      when ''         then 'direct hit'
      else request.env['HTTP_REFERER']
    end
  end
  
  def set_related_lastest_variables
    @favorites = Track.favorites_for_home
    @popular = Asset.limit(5).order('hotness DESC').includes(:user => :pic)
    @playlists = Playlist.for_home
    @comments = admin? ? Comment.last_5_private : Comment.last_5_public
    @followee_tracks = current_user.new_tracks_from_followees(5) if user_has_tracks_from_followees?
  end
  
  def set_related_show_variables
    @listens = @asset.listens
    @comments = @asset.comments.only_public
    @listeners = @asset.listeners.first(5)
    @favoriters = @asset.favoriters
    @page_title = "#{@asset.name} by #{@user.name}"
    @description = @page_title + " - #{@asset[:description]}"
    @single_track = true
  end
  
  def authorized?
    # admin or the owner of the asset can edit/update/delete
    !dangerous_action? || current_user_is_admin_or_owner?(@user) || current_user_is_admin_or_owner?(@asset.user)
  end
  
  def dangerous_action?
    %w(destroy update edit create).include? action_name 
  end
  
  def register_listen
    @asset.listens.create(
      :listener     => current_user || nil, 
      :track_owner  => @asset.user, 
      :source       => @referrer, 
      :user_agent   => @agent,
      :ip           => request.remote_ip
    ) unless is_a_bot?
  end
  
  def is_a_bot?
    # gotta have a user agent
    return true unless request.user_agent.present?
    
    # can't be a blacklisted ip
    return true if is_from_a_bad_ip?
    
    # check user agent agaisnt both white and black lists
    not browser? or @@bots.any?{|bot_agent| @agent.include? bot_agent}  
  end
  
  def browser?
    @@valid_listeners.any?{|valid_agent| @agent.include? valid_agent} 
  end
  
  def set_user_agent
    @agent = request.user_agent.downcase    
  end
  
  def prevent_abuse
    if is_a_bot?
      Rails.logger.error "BOT LISTEN ATTEMPT FAIL: #{@asset.mp3_file_name} #{@agent} #{request.remote_ip} #{@referrer} User:#{current_user || 0}"
      render(:text => "Denied due to abuse", :status => 403)    
    end
  end
end
