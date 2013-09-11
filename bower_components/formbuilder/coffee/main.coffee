class Formbuilder
  @helpers:
    defaultFieldAttrs: (field_type) ->
      attrs =
        label: "Untitled"
        field_type: field_type
        field_options:
          required: true

      Formbuilder.fields[field_type].defaultAttributes?(attrs) || attrs

    simple_format: (x) ->
      x?.replace(/\n/g, '<br />')

  @options:
    BUTTON_CLASS: ''
    HTTP_ENDPOINT: ''
    HTTP_METHOD: 'POST'

    dict:
      ALL_CHANGES_SAVED: 'All changes saved'
      SAVE_FORM: 'Save form'
      UNSAVED_CHANGES: 'You have unsaved changes. If you leave this page, you will lose those changes!'

  @fields: {}
  @inputFields: {}
  @nonInputFields: {}

  @model: Backbone.DeepModel.extend
    sync: -> # noop
    indexInDOM: ->
      $wrapper = $(".response-field-wrapper").filter ( (_, el) => $(el).data('cid') == @cid  )
      $(".response-field-wrapper").index $wrapper
    is_input: ->
      Formbuilder.inputFields[@get('field_type')]?

  @collection: Backbone.Collection.extend
    initialize: ->
      @on 'add', @copyCidToModel

    model: Formbuilder.model

    comparator: (model) ->
      model.indexInDOM()

    copyCidToModel: (model) ->
      model.attributes.cid = model.cid

  @registerField: (name, opts) ->
    for x in ['view', 'edit']
      opts[x] = _.template(opts[x])

    Formbuilder.fields[name] = opts

    if opts.type == 'non_input'
      Formbuilder.nonInputFields[name] = opts
    else
      Formbuilder.inputFields[name] = opts

  @views:
    view_field: Backbone.View.extend
      className: "response-field-wrapper"

      events:
        'click .subtemplate-wrapper': 'focusEditView'
        'click .js-duplicate': 'duplicate'
        'click .js-clear': 'clear'

      initialize: ->
        @parentView = @options.parentView
        @listenTo @model, "change", @render
        @listenTo @model, "destroy", @remove

      render: ->
        @$el.addClass('response-field-'+@model.get('field_type'))
            .data('cid', @model.cid)
            .html(Formbuilder.templates["view/base#{if !@model.is_input() then '_non_input' else ''}"]({rf: @model}))

        return @

      focusEditView: ->
        @parentView.createAndShowEditView(@model)

      clear: ->
        @parentView.handleFormUpdate()
        @model.destroy()

      duplicate: ->
        attrs = _.clone(@model.attributes)
        delete attrs['id']
        attrs['label'] += ' Copy'
        @parentView.createField attrs, { position: @model.indexInDOM() + 1 }
    edit_field: Backbone.View.extend
      className: "edit-response-field"

      events:
        'click .js-add-option': 'addOption'
        'click .js-remove-option': 'removeOption'
        'click .js-default-updated': 'defaultUpdated'
        'input .option-label-input': 'forceRender'

      initialize: ->
        @listenTo @model, "destroy", @remove
        @listenTo @model, "change:field_options.review_this_field", @auditReviewThisFieldChanged

      render: ->
        @$el.html(Formbuilder.templates["edit/base#{if !@model.is_input() then '_non_input' else ''}"]({rf: @model}))
        rivets.bind @$el, { model: @model }
        return @

      remove: ->
        @options.parentView.editView = undefined
        @options.parentView.$el.find("[href=\"#addField\"]").click()
        Backbone.View.prototype.remove.call(@)

      # @todo this should really be on the model, not the view
      addOption: (e) ->
        $el = $(e.currentTarget)
        i = @$el.find('.option').index($el.closest('.option'))
        options = @model.get("field_options.options") || []
        newOption = {label: "", checked: false}

        if i > -1
          options.splice(i + 1, 0, newOption)
        else
          options.push newOption

        @model.set "field_options.options", options
        @model.trigger "change:field_options.options"
        @forceRender()

      removeOption: (e) ->
        $el = $(e.currentTarget)
        index = @$el.find(".js-remove-option").index($el)
        options = @model.get "field_options.options"
        options.splice index, 1
        @model.set "field_options.options", options
        @model.trigger "change:field_options.options"
        @forceRender()

      defaultUpdated: (e) ->
        $el = $(e.currentTarget)

        unless @model.get('field_type') == 'checkboxes' # checkboxes can have multiple options selected
          @$el.find(".js-default-updated").not($el).attr('checked', false).trigger('change')

        @forceRender()

      forceRender: ->
        @model.trigger('change')
    main: Backbone.View.extend
      SUBVIEWS: []

      events:
        'click .js-save-form': 'saveForm'
        'click .fb-tabs a': 'showTab'
        'click .fb-add-field-types a': 'addField'

      initialize: ->
        @$el = $(@options.selector)
        @formBuilder = @options.formBuilder

        # Create the collection, and bind the appropriate events
        @collection = new Formbuilder.collection
        @collection.bind 'add', @addOne, @
        @collection.bind 'reset', @reset, @
        @collection.bind 'change', @handleFormUpdate, @
        @collection.bind 'destroy add reset', @hideShowNoResponseFields, @
        @collection.bind 'destroy', @ensureEditViewScrolled, @

        @render()
        @collection.reset(@options.bootstrapData)
        @initAutosave()

      initAutosave: ->
        @formSaved = true
        @saveFormButton = @$el.find(".js-save-form")
        @saveFormButton.attr('disabled', true).text(Formbuilder.options.dict.ALL_CHANGES_SAVED)

        setInterval =>
          @saveForm.call(@)
        , 5000

        $(window).bind 'beforeunload', =>
          if @formSaved then undefined else Formbuilder.options.dict.UNSAVED_CHANGES

      reset: ->
        @$responseFields.html('')
        @addAll()

      render: ->
        @$el.html Formbuilder.templates['page']()

        # Save jQuery objects for easy use
        @$fbLeft = @$el.find('.fb-left')
        @$responseFields = @$el.find('.fb-response-fields')

        @bindWindowScrollEvent()
        @hideShowNoResponseFields()

        # Render any subviews (this is an easy way of extending the Formbuilder)
        new subview({parentView: @}).render() for subview in @SUBVIEWS

        return @

      bindWindowScrollEvent: ->
        $(window).on 'scroll', =>
          return if @$fbLeft.data('locked') == true
          newMargin = Math.max(0, $(window).scrollTop())
          maxMargin = @$responseFields.height()

          @$fbLeft.css
            'margin-top': Math.min(maxMargin, newMargin)

      showTab: (e) ->
        $el = $(e.currentTarget)
        target = $el.data('target')
        $el.closest('li').addClass('active').siblings('li').removeClass('active')
        $(target).addClass('active').siblings('.fb-tab-pane').removeClass('active')

        @unlockLeftWrapper() unless target == '#editField'

        if target == '#editField' && !@editView && (first_model = @collection.models[0])
          @createAndShowEditView(first_model)

      addOne: (responseField, _, options) ->
        view = new Formbuilder.views.view_field
          model: responseField
          parentView: @

        #####
        # Calculates where to place this new field.
        #
        # Are we replacing a temporarily drag placeholder?
        if options.$replaceEl?
          options.$replaceEl.replaceWith(view.render().el)

        # Are we adding to the bottom?
        else if !options.position? || options.position == -1
          @$responseFields.append view.render().el

        # Are we adding to the top?
        else if options.position == 0
          @$responseFields.prepend view.render().el

        # Are we adding below an existing field?
        else if ($replacePosition = @$responseFields.find(".response-field-wrapper").eq(options.position))[0]
          $replacePosition.before view.render().el

        # Catch-all: add to bottom
        else
          @$responseFields.append view.render().el

      setSortable: ->
        @$responseFields.sortable('destroy') if @$responseFields.hasClass('ui-sortable')
        @$responseFields.sortable
          forcePlaceholderSize: true
          placeholder: 'sortable-placeholder'
          stop: (e, ui) =>
            if ui.item.data('field-type')
              rf = @collection.create Formbuilder.helpers.defaultFieldAttrs(ui.item.data('field-type')), {$replaceEl: ui.item}
              @createAndShowEditView(rf)

            @handleFormUpdate()
            return true
          update: (e, ui) =>
            # ensureEditViewScrolled, unless we're updating from the draggable
            @ensureEditViewScrolled() unless ui.item.data('field-type')

        @setDraggable()

      setDraggable: ->
        $addFieldButtons = @$el.find("[data-field-type]")

        $addFieldButtons.draggable
          connectToSortable: @$responseFields
          helper: =>
            $helper = $("<div class='response-field-draggable-helper' />")
            $helper.css
              width: @$responseFields.width() # hacky, won't get set without inline style
              height: '80px'

            $helper

      addAll: ->
        @collection.each @addOne, @
        @setSortable()

      hideShowNoResponseFields: ->
        @$el.find(".fb-no-response-fields")[if @collection.length > 0 then 'hide' else 'show']()

      addField: (e) ->
        field_type = $(e.currentTarget).data('field-type')
        @createField Formbuilder.helpers.defaultFieldAttrs(field_type)

      createField: (attrs, options) ->
        rf = @collection.create attrs, options
        @createAndShowEditView(rf)
        @handleFormUpdate()

      createAndShowEditView: (model) ->
        $responseFieldEl = @$el.find(".response-field-wrapper").filter( -> $(@).data('cid') == model.cid )
        $responseFieldEl.addClass('editing').siblings('.response-field-wrapper').removeClass('editing')

        if @editView
          if @editView.model.cid is model.cid
            @$el.find(".fb-tabs a[data-target=\"#editField\"]").click()
            @scrollLeftWrapper $responseFieldEl, (oldPadding? && oldPadding)
            return

          oldPadding = @$fbLeft.css('padding-top')
          @editView.remove()

        @editView = new Formbuilder.views.edit_field
          model: model
          parentView: @

        $newEditEl = @editView.render().$el
        @$el.find("#edit-response-field-wrapper").html $newEditEl
        @$el.find(".fb-tabs a[data-target=\"#editField\"]").click()
        @scrollLeftWrapper($responseFieldEl)
        return @

      ensureEditViewScrolled: ->
        return unless @editView
        @scrollLeftWrapper $(".response-field-wrapper.editing")

      scrollLeftWrapper: ($responseFieldEl) ->
        @unlockLeftWrapper()
        $.scrollWindowTo ($responseFieldEl.offset().top - @$responseFields.offset().top), 200, =>
          @lockLeftWrapper()

      lockLeftWrapper: ->
        @$fbLeft.data('locked', true)

      unlockLeftWrapper: ->
        @$fbLeft.data('locked', false)

      handleFormUpdate: ->
        return if @updatingBatch
        @formSaved = false
        @saveFormButton.removeAttr('disabled').text(Formbuilder.options.dict.SAVE_FORM)

      saveForm: (e) ->
        return if @formSaved
        @formSaved = true
        @saveFormButton.attr('disabled', true).text(Formbuilder.options.dict.ALL_CHANGES_SAVED)
        @collection.sort()
        payload = JSON.stringify fields: @collection.toJSON()

        if Formbuilder.options.HTTP_ENDPOINT then @doAjaxSave(payload)
        @formBuilder.trigger 'save', payload

      doAjaxSave: (payload) ->
        $.ajax
          url: Formbuilder.options.HTTP_ENDPOINT
          type: Formbuilder.options.HTTP_METHOD
          data: payload
          success: (data) =>
            @updatingBatch = true

            for datum in data
              # set the IDs of new response fields, returned from the server
              @collection.get(datum.cid)?.set({id: datum.id})
              @collection.trigger 'sync'

            @updatingBatch = undefined

  constructor: (selector) ->
    _.extend @, Backbone.Events
    @mainView = new Formbuilder.views.main({ selector: selector, formBuilder: @ })

window.Formbuilder = Formbuilder

if module?
  module.exports = Formbuilder
else
  window.Formbuilder = Formbuilder